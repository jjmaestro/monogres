package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
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
import jakarta.inject.Inject;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// One archive out of however many an extension has can arrive as something no tar reader can
/// open, and which one is the forge's decision rather than the config's. What the rest of the run
/// does about it is what these pin.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchArchiveFailureTest {
  private static final String CONFIG =
      """
      {
        "name": "%s",
        "url": "https://github.com/monogres/%s",
        "versions": { "replace": [["^v(.*)$", "$1"]] }
      }
      """;

  /// What a forge answering with something other than an archive leaves on disk: a file with no
  /// gzip header, which is as far as a reader of it gets.
  private static final byte[] NOT_AN_ARCHIVE = "<html>404</html>".getBytes(StandardCharsets.UTF_8);

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  private final Map<String, byte[]> archivesByCommit = new HashMap<>();

  private void serve(String extension, String version, String seed) throws IOException {
    var commit = PipelineFixture.commitSha(seed);
    archivesByCommit.put(
        commit,
        PipelineFixture.controlArchive(
            extension, extension + "-" + commit, PipelineFixture.control(version, version), 0L));
  }

  private void serveUnreadable(String seed) {
    archivesByCommit.put(PipelineFixture.commitSha(seed), NOT_AN_ARCHIVE);
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
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
    archivesByCommit.clear();

    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              var commit = target.getFileName().toString().replace(".tar.gz", "");
              var bytes = archivesByCommit.get(commit);
              assertNotNull(bytes, "no archive registered for commit " + commit);
              Files.createDirectories(target.getParent());
              Files.write(target, bytes);
              return Future.succeededFuture(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
            });
  }

  @Test
  void theVersionsAroundAnUnreadableArchiveAreStillCatalogued() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture", "fixture"));
    serve("fixture", "0.1.0", "aa1");
    serveUnreadable("aa2");
    serve("fixture", "0.3.0", "aa3");
    when(tagLister.getTags(any()))
        .thenReturn(
            new GitTag[] {
              new GitTag("v0.3.0", PipelineFixture.objectId("aa3")),
              new GitTag("v0.2.0", PipelineFixture.objectId("aa2")),
              new GitTag("v0.1.0", PipelineFixture.objectId("aa1"))
            });

    run();

    assertEquals(List.of("0.3.0", "0.1.0"), versionsIn("extensions/fixture"));
  }

  @Test
  void anUnreadableArchiveInOneExtensionLeavesTheOthersAlone() throws Exception {
    PipelineFixture.writeConfig("extensions/alpha", CONFIG.formatted("alpha", "alpha"));
    PipelineFixture.writeConfig("extensions/beta", CONFIG.formatted("beta", "beta"));
    serve("alpha", "1.0.0", "a1");
    serveUnreadable("b1");
    when(tagLister.getTags(any()))
        .thenAnswer(
            invocation -> {
              var url = invocation.getArgument(0).toString();
              return url.endsWith("alpha")
                  ? new GitTag[] {new GitTag("v1.0.0", PipelineFixture.objectId("a1"))}
                  : new GitTag[] {new GitTag("v2.0.0", PipelineFixture.objectId("b1"))};
            });

    run();

    assertEquals(List.of("1.0.0"), versionsIn("extensions/alpha"));
    assertFalse(
        Files.exists(PipelineFixture.repoJson("extensions/beta")),
        "an extension whose only archive is unreadable catalogues nothing");
  }
}
