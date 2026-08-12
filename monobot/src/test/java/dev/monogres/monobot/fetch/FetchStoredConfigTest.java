package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
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
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// A file the run reads before it does anything else, and cannot read. Every extension owns its
/// own `monobot.json` and its own stored `repo.json`, so one of them being unreadable says nothing
/// about the others and has to cost only the extension it belongs to.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchStoredConfigTest {
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

  /// A document cut off partway, which is what a write interrupted in place leaves behind.
  private static final String TORN_REPO_JSON =
      """
      {
        "sources" : {
          "github.com" : {
            "url" : "https://api.github.com/repos/monogres/beta/tarball/{commit}",
            "type" : "tar.g\
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  private final Map<String, byte[]> archivesByVersion = new HashMap<>();

  private void serve(String extension, String version) throws IOException {
    archivesByVersion.put(
        version,
        PipelineFixture.controlArchive(
            extension, extension + "-" + version, PipelineFixture.control(version, version), 0L));
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

    when(tagLister.getTags(any()))
        .thenAnswer(
            invocation -> {
              var url = invocation.getArgument(0).toString();
              return url.endsWith("alpha")
                  ? new GitTag[] {new GitTag("v1.0.0", PipelineFixture.objectId("a1"))}
                  : new GitTag[] {new GitTag("v2.0.0", PipelineFixture.objectId("b1"))};
            });

    when(sourceArchive.download(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              var version = target.getParent().getFileName().toString();
              var bytes = archivesByVersion.get(version);
              assertNotNull(bytes, "no archive registered for version " + version);
              return PipelineFixture.served(target, bytes);
            });
  }

  @Test
  void oneTornRepoJsonLeavesTheOtherExtensionsAlone() throws Exception {
    PipelineFixture.writeConfig("extensions/alpha", CONFIG.formatted("alpha"));
    PipelineFixture.writeConfig("extensions/beta", CONFIG.formatted("beta"));
    PipelineFixture.writeRepoJson("extensions/beta", TORN_REPO_JSON);
    serve("alpha", "1.0.0");
    serve("beta", "2.0.0");

    awaitSettled(scan.run());

    assertEquals(List.of("1.0.0"), versionsIn("extensions/alpha"));
    assertEquals(
        TORN_REPO_JSON,
        Files.readString(PipelineFixture.repoJson("extensions/beta")),
        "the run replaced a stored document it could not read");
  }

  @Test
  void oneMalformedMonobotJsonLeavesTheOtherExtensionsAlone() throws Exception {
    PipelineFixture.writeConfig("extensions/alpha", CONFIG.formatted("alpha"));
    PipelineFixture.writeConfig("extensions/beta", "{ \"name\": \"beta\", ");
    serve("alpha", "1.0.0");

    awaitSettled(scan.run());

    assertEquals(List.of("1.0.0"), versionsIn("extensions/alpha"));
    assertFalse(
        Files.exists(PipelineFixture.repoJson("extensions/beta")),
        "an extension whose config cannot be read catalogues nothing");
  }

  @Test
  void theRunReportsAnUnreadableStoredDocument() throws Exception {
    PipelineFixture.writeConfig("extensions/beta", CONFIG.formatted("beta"));
    PipelineFixture.writeRepoJson("extensions/beta", TORN_REPO_JSON);

    var scanFuture = scan.run();
    awaitSettled(scanFuture);

    assertTrue(scanFuture.failed(), "the run reported nothing about a file it could not read");
  }
}
