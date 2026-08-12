package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
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
import jakarta.inject.Inject;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// Where a run puts what it wrote. The config tree is the only thing that says which extension an
/// output belongs to, so an output path that keeps less of it than the tree carries cannot
/// distinguish two extensions the tree distinguishes.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchOutputPathTest {
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

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();

    // Which archive to serve is read out of the URL rather than out of the path it is asked to be
    // written to. Two configs can share the leaf of their path, which is the point of this test,
    // and the URL is what tells the two of them apart.
    when(sourceArchive.download(any(), any()))
        .thenAnswer(
            invocation -> {
              var url = invocation.getArgument(0).toString();
              Path target = invocation.getArgument(1);
              var version = target.getParent().getFileName().toString();
              var extension = url.replaceFirst(".*/monogres/([^/]+)/archive/.*", "$1");
              var bytes =
                  PipelineFixture.controlArchive(
                      extension,
                      extension + "-" + version,
                      PipelineFixture.control("1.0.0", extension),
                      0L);

              return PipelineFixture.served(target, bytes);
            });
  }

  /// The comment the archive at this path carried, read out of the control file the run wrote
  /// beside the entry. It names the extension, so it is what says which entry a document is.
  private String commentIn(String relativeDir) throws Exception {
    var written = PipelineFixture.repoJson(relativeDir);
    assertTrue(Files.exists(written), "the pipeline wrote no repo.json at " + written);

    return objectMapper
        .readTree(written.getParent().resolve("metadata/1.0.0/control.json").toFile())
        .get("comment")
        .asText();
  }

  @Test
  void outputMirrorsTheConfigPathBelowConfigDir() throws Exception {
    PipelineFixture.writeConfig("extensions/envvar", CONFIG.formatted("envvar"));
    when(tagLister.getTags(any()))
        .thenReturn(new GitTag[] {new GitTag("v1.0.0", PipelineFixture.objectId("a1"))});

    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);

    assertEquals("envvar", commentIn("extensions/envvar"));
  }

  @Test
  void twoConfigsSharingLeafNameDoNotOverwriteEachOther() throws Exception {
    PipelineFixture.writeConfig("extensions/envvar", CONFIG.formatted("envvar"));
    PipelineFixture.writeConfig("contrib/envvar", CONFIG.formatted("contrib"));
    when(tagLister.getTags(any()))
        .thenReturn(new GitTag[] {new GitTag("v1.0.0", PipelineFixture.objectId("a1"))});

    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);

    assertEquals("envvar", commentIn("extensions/envvar"));
    assertEquals("contrib", commentIn("contrib/envvar"));
  }
}
