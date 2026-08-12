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

/// The bound is over the whole scan rather than over one extension, which is the reason
/// [DownloadLimiter] is application scoped: a scan starts every extension at once and each of them
/// every one of its versions, so a per-extension cap would multiply by however many configs the
/// tree happens to hold. With one extension a per-extension cap and a global one are the same
/// number, so only a second extension can tell them apart.
@QuarkusTest
@TestProfile(BoundedDownloadTestProfile.class)
class FetchDownloadBoundAcrossExtensionsTest {
  private static final int VERSIONS_PER_EXTENSION = 4;

  /// Named for a hex digit each, because a commit id is synthesised by padding the name out to
  /// forty characters and JGit will not read one that is not hex.
  private static final List<String> EXTENSIONS = List.of("ax", "bx", "cx");

  private static final String CONFIG =
      """
      {
        "name": "%1$s",
        "url": "https://github.com/monogres/%1$s",
        "sources": {
          "gh": {
            "tag": "v{version}",
            "name": "%1$s",
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

  private final CountDownLatch bound = new CountDownLatch(BoundedDownloadTestProfile.LIMIT);

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    asked.clear();
    pending.clear();

    for (var extension : EXTENSIONS) {
      PipelineFixture.writeConfig("extensions/" + extension, CONFIG.formatted(extension));
    }

    when(tagLister.getTags(any()))
        .thenAnswer(
            invocation -> {
              var url = invocation.getArgument(0).toString();
              var extension = url.substring(url.lastIndexOf('/') + 1);
              var tags = new ArrayList<GitTag>();
              for (var version = 1; version <= VERSIONS_PER_EXTENSION; version++) {
                tags.add(
                    new GitTag(
                        "v0." + version + ".0",
                        PipelineFixture.objectId(extension.charAt(0) + "a" + version)));
              }

              return tags.toArray(GitTag[]::new);
            });

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
  /// permits still held starves whatever runs next. Every download left in flight is settled here,
  /// including the ones the settling starts.
  @AfterEach
  void tearDown() {
    for (var settled = 0; settled < pending.size(); settled++) {
      pending.get(settled).tryFail(new IllegalStateException("the test ended"));
    }
  }

  /// The scheduling passes run on workers, so how many downloads have been asked for has to be
  /// waited for rather than read. Once the bound is reached the count stops moving on its own.
  private void awaitAsked(int expected) throws Exception {
    var deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30);
    while (asked.size() < expected && System.nanoTime() < deadline) {
      TimeUnit.MILLISECONDS.sleep(5);
    }

    assertEquals(
        expected,
        asked.size(),
        "the downloads in flight are not the ones the bound allows at this point");
  }

  private void release(int index) throws Exception {
    var target = asked.get(index);
    var version = target.getParent().getFileName().toString();
    var extension = target.getParent().getParent().getFileName().toString();
    var bytes =
        PipelineFixture.controlArchive(
            extension, extension + "-" + version, PipelineFixture.control(version, version), 0L);
    Files.createDirectories(target.getParent());
    Files.write(target, bytes);
    pending.get(index).complete(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
  }

  @Test
  void theBoundHoldsAcrossEveryExtensionAtOnce() throws Exception {
    var total = EXTENSIONS.size() * VERSIONS_PER_EXTENSION;
    final var scanFuture = scan.run();

    assertTrue(bound.await(60, TimeUnit.SECONDS), "the scheduling passes never reached the bound");
    assertEquals(
        BoundedDownloadTestProfile.LIMIT,
        asked.size(),
        "three extensions were each allowed the whole bound rather than sharing it");

    for (var released = 0; released < total; released++) {
      release(released);
      awaitAsked(Math.min(total, released + 1 + BoundedDownloadTestProfile.LIMIT));
    }

    scanFuture.toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);

    for (var extension : EXTENSIONS) {
      var written = PipelineFixture.repoJson("extensions/" + extension);
      assertTrue(Files.exists(written), "the pipeline wrote no repo.json at " + written);
      assertEquals(
          VERSIONS_PER_EXTENSION, objectMapper.readTree(written.toFile()).get("versions").size());
    }
  }
}
