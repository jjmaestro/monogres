package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.digest.DigestUtils;
import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.TagLister;
import dev.monogres.monobot.scan.Scan;
import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.TestProfile;
import io.vertx.core.Promise;
import jakarta.inject.Inject;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// The scheduling pass hands every surviving tag to the HTTP client in one go, so without a bound
/// the requests in flight are as many as the forge has tags, times however many extensions the
/// scan found. The forges rate limit anonymous callers, so the bound is what keeps a large scan
/// from being one.
///
/// The stand-in never completes on its own: the test releases downloads one at a time and counts
/// how many have been asked for, which is the only way to observe a bound directly.
@QuarkusTest
@TestProfile(BoundedDownloadTestProfile.class)
class FetchDownloadBoundTest {
  private static final String EXTENSION_DIR = "extensions/fixture";
  private static final int VERSIONS = 6;

  private static final String CONFIG =
      """
      {
        "name": "fixture",
        "url": "https://github.com/monogres/fixture",
        "sources": {
          "gh": {
            "tag": "v{version}",
            "name": "fixture",
            "strip_prefix": "{name}-{version}",
            "url": "https://github.com/monogres/{name}/archive/refs/tags/{tag}.tar.gz"
          }
        },
        "versions": { "discover": { "replace": [["^v(.*)$", "$1"]] } }
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  private final List<Path> asked = Collections.synchronizedList(new ArrayList<>());
  private final List<Promise<String>> pending = Collections.synchronizedList(new ArrayList<>());

  /// The scheduling pass runs on a worker, so how far it has got has to be waited for rather than
  /// read. Once the bound is reached the count stops moving on its own: nothing else is asked for
  /// until a download settles, and this test is the only thing that settles one.
  private final CountDownLatch bound = new CountDownLatch(BoundedDownloadTestProfile.LIMIT);

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    asked.clear();
    pending.clear();
    PipelineFixture.writeConfig(EXTENSION_DIR, CONFIG);

    var tags = new ArrayList<GitTag>();
    for (var i = 1; i <= VERSIONS; i++) {
      tags.add(new GitTag("v0." + i + ".0", PipelineFixture.objectId("aa" + i)));
    }
    when(tagLister.getTags(any())).thenReturn(tags.toArray(GitTag[]::new));

    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              asked.add(invocation.getArgument(1));
              bound.countDown();
              var promise = Promise.<String>promise();
              pending.add(promise);
              return promise.future();
            });
  }

  /// The limiter is application scoped, so it outlives one test class: a test that ends with
  /// permits still held starves whatever runs next.
  @AfterEach
  void tearDown() {
    for (var settled = 0; settled < pending.size(); settled++) {
      pending.get(settled).tryFail(new IllegalStateException("the test ended"));
    }
  }

  private void release(int index) throws Exception {
    var target = asked.get(index);
    var version = target.getParent().getFileName().toString();
    var bytes =
        PipelineFixture.controlArchive(
            "fixture", "fixture-" + version, PipelineFixture.control(version, version), 0L);
    Files.createDirectories(target.getParent());
    Files.write(target, bytes);
    pending.get(index).complete(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
  }

  @Test
  void noMoreDownloadsAreAskedForThanTheBoundAllows() throws Exception {
    final var scanFuture = scan.run();

    assertTrue(bound.await(60, TimeUnit.SECONDS), "the scheduling pass never reached the bound");
    assertEquals(
        BoundedDownloadTestProfile.LIMIT,
        asked.size(),
        "the scheduling pass asked for more downloads than the bound allows");

    for (var released = 0; released < VERSIONS; released++) {
      release(released);
      assertEquals(
          Math.min(VERSIONS, released + 1 + BoundedDownloadTestProfile.LIMIT),
          asked.size(),
          "releasing one download has to let exactly one more start");
    }

    scanFuture.toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);

    var written = PipelineFixture.repoJson(EXTENSION_DIR);
    assertTrue(Files.exists(written), "the pipeline wrote no repo.json at " + written);
    assertEquals(VERSIONS, objectMapper.readTree(written.toFile()).get("versions").size());
  }
}
