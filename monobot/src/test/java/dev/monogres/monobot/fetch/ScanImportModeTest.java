package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.input.MonobotConfig;
import dev.monogres.monobot.git.TagLister;
import dev.monogres.monobot.scan.Scan;
import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.TestProfile;
import jakarta.inject.Inject;
import java.nio.file.Files;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// The mode that walks the catalog by its `repo.json` files rather than its `monobot.json` ones,
/// which is what a tree that has only the first can be started from.
@QuarkusTest
@TestProfile(ImportModeTestProfile.class)
class ScanImportModeTest {
  private static final String EXTENSION_DIR = "extensions/vector";

  private static final String REPO_JSON =
      """
      {
        "version": 1,
        "sources": {
          "gh": {
            "tag": "v{version}",
            "gh_org": "pgvector",
            "name": "pgvector",
            "strip_prefix": "{name}-{version}",
            "url": "https://github.com/{gh_org}/{name}/archive/refs/tags/{tag}.tar.gz"
          }
        },
        "versions": {
          "0.8.2": {
            "sha256": "915ee9d0b1a4dc0f5f5a4b52530b9c8ba1e07b7addb43e3b7f6bd2b64f0b7b7a"
          }
        },
        "metadata": {
          "compatible_with": {
            "postgres": ">=13"
          }
        }
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    PipelineFixture.writeRepoJson(EXTENSION_DIR, REPO_JSON);
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  private String monobotJson() throws Exception {
    return Files.readString(
        PipelineFixture.CATALOG_DIR.resolve(EXTENSION_DIR).resolve("monobot.json"));
  }

  /// The whole point of the mode: a derivation over files already on disk, so it neither lists a
  /// tag nor downloads an archive.
  @Test
  void importingAsksNothingOfTheNetwork() throws Exception {
    run();

    verify(tagLister, never()).getTags(any());
    verify(sourceArchive, never()).download(any(), any());
  }

  @Test
  void whatItWritesIsSomethingMonobotReads() throws Exception {
    run();

    var config = objectMapper.readValue(monobotJson(), MonobotConfig.class);

    assertEquals("vector", config.name(), "the control stem is the entry's own directory");
    assertEquals(
        List.of("0.8.2"),
        config.versionsSpec().pin().keySet().stream().map(version -> version.version()).toList());
    assertTrue(config.versionsSpec().discovery().isEmpty(), "a discover block was invented");
  }

  /// `repo.json` is what is being read, so it is the one thing the mode has no business changing.
  @Test
  void theCatalogItReadsIsLeftExactlyAsItWas() throws Exception {
    run();

    assertEquals(REPO_JSON, Files.readString(PipelineFixture.repoJson(EXTENSION_DIR)));
  }

  /// A contrib extension is built with Postgres and downloaded with nothing, so its entry is a
  /// manifest of installed files. The catalog holds 70 of them and there is no `monobot.json` that
  /// generates one.
  @Test
  void anEntryNamingNoArchiveIsPassedOver() throws Exception {
    PipelineFixture.writeRepoJson(
        "extensions/contrib/pg_trgm", "{\"kind\": \"contrib\", \"metadata\": {\"files\": {}}}");

    run();

    assertFalse(
        Files.exists(
            PipelineFixture.CATALOG_DIR
                .resolve("extensions/contrib/pg_trgm")
                .resolve("monobot.json")),
        "a config was written for an entry that names no archive");
  }

  /// A `repo.json` that cannot be read is one entry, and the tree holds one per entry, so it is
  /// reported against that entry and the run still says one failed.
  @Test
  void anEntryThatCannotBeReadFailsTheRunAndNotTheOthers() throws Exception {
    PipelineFixture.writeRepoJson("extensions/torn", "{\"versions\": ");

    assertThrows(ExecutionException.class, this::run);

    assertTrue(
        Files.exists(PipelineFixture.CATALOG_DIR.resolve(EXTENSION_DIR).resolve("monobot.json")),
        "the readable entry was not imported");
    assertFalse(
        Files.exists(
            PipelineFixture.CATALOG_DIR.resolve("extensions/torn").resolve("monobot.json")),
        "a config was written for an entry that could not be read");
  }
}
