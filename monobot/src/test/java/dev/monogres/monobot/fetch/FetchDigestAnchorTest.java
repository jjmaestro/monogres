package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
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
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// What happens when the archive behind a catalogued version turns out to hold different bytes.
///
/// The catalog is a set of curated pins and every digest in it was settled when the version was
/// added. A source answering the same URL with different bytes is the artifact changing underneath
/// one, and a run that recorded the new digest would report that as a one-line diff. So the run
/// keeps what is catalogued, names both digests and fails the entry.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchDigestAnchorTest {
  private static final String EXTENSION_DIR = "extensions/fixture";
  private static final String VERSION = "0.1.0";

  private static final String CONFIG =
      """
      {
        "name": "fixture",
        "sources": {
          "gh": {
            "tag": "v{version}",
            "name": "fixture",
            "strip_prefix": "{name}-{version}",
            "url": "https://github.com/monogres/{name}/archive/refs/tags/{tag}.tar.gz"
          }
        },
        "versions": { "pin": ["0.1.0"] }
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  private final AtomicReference<String> served = new AtomicReference<>("the archive as published");

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    PipelineFixture.writeConfig(EXTENSION_DIR, CONFIG);
    served.set("the archive as published");

    when(tagLister.getTags(any())).thenReturn(new GitTag[] {});
    when(sourceArchive.download(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);

              return PipelineFixture.served(
                  target,
                  PipelineFixture.controlArchive(
                      "fixture",
                      "fixture-" + VERSION,
                      PipelineFixture.control(VERSION, served.get()),
                      0L));
            });
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  /// The archive has to be fetched again for the question to come up at all, and the cache would
  /// otherwise answer for it, so what the source now serves never reaches the digest.
  private void republish(String content) throws Exception {
    served.set(content);
    PipelineFixture.deleteRecursively(PipelineFixture.CACHE_DIR);
  }

  private String catalogued() throws Exception {
    return objectMapper
        .readTree(PipelineFixture.repoJson(EXTENSION_DIR).toFile())
        .path("versions")
        .path(VERSION)
        .path("sha256")
        .asText();
  }

  @Test
  void versionsKeepTheDigestTheCatalogRecordsForThem() throws Exception {
    run();
    var settled = catalogued();

    republish("the archive as rebuilt");
    assertThrows(ExecutionException.class, this::run);

    assertEquals(settled, catalogued(), "the catalogued digest was written over");
  }

  @Test
  void theRunSaysSoRatherThanExitingCleanly() throws Exception {
    run();

    republish("the archive as rebuilt");
    var failure = assertThrows(ExecutionException.class, this::run);

    assertNotEquals(
        -1,
        failure.getMessage().indexOf("digests disagree"),
        "the failure does not say what happened: " + failure.getMessage());
  }

  /// The same archive over and over is the steady state, and the whole point of the check is that
  /// it costs nothing to be in it.
  @Test
  void anArchiveThatStillDigestsToWhatIsCataloguedPassesQuietly() throws Exception {
    run();
    var settled = catalogued();

    PipelineFixture.deleteRecursively(PipelineFixture.CACHE_DIR);
    run();

    assertEquals(settled, catalogued());
  }

  /// The first run has nothing to hold the version to, which is how a version is added at all.
  @Test
  void versionsNothingHasCataloguedYetAreWrittenAsWhatTheyAre() throws Exception {
    run();

    assertEquals(64, catalogued().length(), "no digest was catalogued for a new version");
    assertEquals(
        1,
        Files.list(PipelineFixture.CACHE_DIR.resolve(EXTENSION_DIR)).count(),
        "the run cached something other than the one version it names");
  }
}
