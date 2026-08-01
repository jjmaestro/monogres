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
import io.vertx.core.Future;
import jakarta.inject.Inject;
import java.nio.ByteBuffer;
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
        "name": "%s",
        "url": "https://github.com/monogres/%s"
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();

    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              var commit = target.getFileName().toString().replace(".tar.gz", "");
              var extension = target.getParent().getFileName().toString();
              var bytes =
                  PipelineFixture.controlArchive(
                      extension,
                      extension + "-" + commit,
                      PipelineFixture.control("1.0.0", extension),
                      0L);
              Files.createDirectories(target.getParent());
              Files.write(target, bytes);
              return Future.succeededFuture(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
            });
  }

  private String commentIn(String relativeDir) throws Exception {
    var written = PipelineFixture.repoJson(relativeDir);
    assertTrue(Files.exists(written), "the pipeline wrote no repo.json at " + written);
    return objectMapper
        .readTree(written.toFile())
        .get("metadata")
        .get(".control")
        .get("1.0.0")
        .get("comment")
        .asText();
  }

  @Test
  void outputMirrorsTheConfigPathBelowConfigDir() throws Exception {
    PipelineFixture.writeConfig("extensions/envvar", CONFIG.formatted("envvar", "envvar"));
    when(tagLister.getTags(any()))
        .thenReturn(new GitTag[] {new GitTag("v1.0.0", PipelineFixture.objectId("a1"))});

    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);

    assertEquals("envvar", commentIn("extensions/envvar"));
  }

  @Test
  void twoConfigsSharingLeafNameDoNotOverwriteEachOther() throws Exception {
    PipelineFixture.writeConfig("extensions/envvar", CONFIG.formatted("envvar", "envvar"));
    PipelineFixture.writeConfig("contrib/envvar", CONFIG.formatted("contrib", "contrib"));
    when(tagLister.getTags(any()))
        .thenReturn(new GitTag[] {new GitTag("v1.0.0", PipelineFixture.objectId("a1"))});

    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);

    assertEquals("envvar", commentIn("extensions/envvar"));
    assertEquals("contrib", commentIn("contrib/envvar"));
  }
}
