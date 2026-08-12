package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
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
import io.vertx.core.Future;
import io.vertx.core.Promise;
import jakarta.inject.Inject;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// A download the forge does not serve. It is the one failure that reaches the future graph at
/// all: a tag listing that fails is reported and skipped, an archive that will not open is
/// reported and skipped, and a status the forge answers with fails the download.
///
/// What the rest of the run does about it is what these pin. One archive is one version, so losing
/// it costs that version and nothing else: not the versions of the same extension that downloaded
/// beside it, and not the extensions the scan had not reached.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchDownloadFailureTest {
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

  private final Map<String, byte[]> archivesByVersion = new HashMap<>();
  private final Set<String> refusedVersions = new HashSet<>();

  private void serve(String extension, String version) throws IOException {
    archivesByVersion.put(
        version,
        PipelineFixture.controlArchive(
            extension, extension + "-" + version, PipelineFixture.control(version, version), 0L));
  }

  private void refuse(String version) {
    refusedVersions.add(version);
  }

  private static GitTag tag(String name, String seed) {
    return new GitTag(name, PipelineFixture.objectId(seed));
  }

  private Future<Void> run() throws IOException {
    return scan.run();
  }

  private static void awaitSettled(Future<Void> future) throws Exception {
    var settled = Promise.<Void>promise();
    future.onComplete(outcome -> settled.complete());
    settled.future().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  private List<String> versionsIn(String relativeDir) throws IOException {
    var path = PipelineFixture.repoJson(relativeDir);
    assertTrue(Files.exists(path), "the pipeline wrote no repo.json at " + path);
    var out = new ArrayList<String>();
    objectMapper.readTree(path.toFile()).get("versions").fieldNames().forEachRemaining(out::add);

    return out;
  }

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    archivesByVersion.clear();
    refusedVersions.clear();

    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              var target = invocation.<java.nio.file.Path>getArgument(1);
              var version = target.getParent().getFileName().toString();
              if (refusedVersions.contains(version)) {
                return Future.failedFuture(new IOException("HTTP 429 Too Many Requests"));
              }
              var bytes = archivesByVersion.get(version);
              assertNotNull(bytes, "no archive registered for version " + version);
              Files.createDirectories(target.getParent());
              Files.write(target, bytes);
              return Future.succeededFuture(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
            });
  }

  @Test
  void oneRefusedDownloadKeepsTheVersionsBesideIt() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture"));
    serve("fixture", "0.1.0");
    refuse("0.2.0");
    serve("fixture", "0.3.0");
    when(tagLister.getTags(any()))
        .thenReturn(
            new GitTag[] {tag("v0.3.0", "aa3"), tag("v0.2.0", "aa2"), tag("v0.1.0", "aa1")});

    awaitSettled(run());

    assertEquals(List.of("0.3.0", "0.1.0"), versionsIn("extensions/fixture"));
  }

  @Test
  void oneRefusedDownloadLeavesTheOtherExtensionsAlone() throws Exception {
    PipelineFixture.writeConfig("extensions/alpha", CONFIG.formatted("alpha"));
    PipelineFixture.writeConfig("extensions/beta", CONFIG.formatted("beta"));
    serve("alpha", "1.0.0");
    refuse("2.0.0");
    when(tagLister.getTags(any()))
        .thenAnswer(
            invocation -> {
              var url = invocation.getArgument(0).toString();
              return url.endsWith("alpha")
                  ? new GitTag[] {tag("v1.0.0", "a1")}
                  : new GitTag[] {tag("v2.0.0", "b1")};
            });

    awaitSettled(run());

    assertEquals(List.of("1.0.0"), versionsIn("extensions/alpha"));
  }

  @Test
  void theRunReportsThatSomeDownloadWasRefused() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture"));
    serve("fixture", "0.1.0");
    refuse("0.2.0");
    when(tagLister.getTags(any()))
        .thenReturn(new GitTag[] {tag("v0.2.0", "aa2"), tag("v0.1.0", "aa1")});

    var scanFuture = run();
    awaitSettled(scanFuture);

    assertTrue(scanFuture.failed(), "the run reported nothing about a download it could not make");
  }
}
