package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
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
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// `after` selects on the newest modification time inside the archive, which exists only once the
/// bytes are on disk. So it runs on the download's continuation rather than beside the range that
/// reads the tag, and it can reduce what a run records but never what it fetches.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchCutoffTest {
  private static final String EXTENSION_DIR = "extensions/fixture";

  private static final long BEFORE_CUTOFF = Instant.parse("2019-06-01T00:00:00Z").toEpochMilli();
  private static final long AFTER_CUTOFF = Instant.parse("2021-06-01T00:00:00Z").toEpochMilli();

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
        "versions": {
          "discover": {
            "replace": [["^v(.*)$", "$1"]],
            "after": "2020-01-01T00:00:00Z"%s
          }
        }
      }
      """;

  private static final String KEEP_NEWEST = ", \"keepNewest\": true";

  private static final String STORED_REPO =
      """
      {
        "version": 1,
        "sources": {
          "gh": {
            "tag": "v{version}",
            "name": "fixture",
            "strip_prefix": "{name}-{version}",
            "url": "https://github.com/monogres/{name}/archive/refs/tags/{tag}.tar.gz"
          }
        },
        "versions": {
          "0.9.0": {
            "sha256": "1111111111111111111111111111111111111111111111111111111111111111"
          }
        },
        "metadata": {
          "compatible_with": {
            "postgres": {
              "0.9.0": ">=12"
            }
          }
        }
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  private final List<String> downloadedVersions = new ArrayList<>();

  /// Newest modification time inside each version's archive, which is what the cutoff reads.
  private final Map<String, Long> modifiedByVersion = new HashMap<>();

  private void archiveModifiedAt(String version, long modified) {
    modifiedByVersion.put(version, modified);
  }

  private void listTags(String... versions) throws Exception {
    var tags = new ArrayList<GitTag>();
    for (var version : versions) {
      tags.add(new GitTag("v" + version, PipelineFixture.objectId("aa" + version.charAt(2))));
    }
    when(tagLister.getTags(any())).thenReturn(tags.toArray(GitTag[]::new));
  }

  private void keepNewest(boolean keepNewest) throws IOException {
    PipelineFixture.writeConfig(EXTENSION_DIR, CONFIG.formatted(keepNewest ? KEEP_NEWEST : ""));
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  private List<String> versionsWritten() throws IOException {
    var path = PipelineFixture.repoJson(EXTENSION_DIR);
    assertTrue(Files.exists(path), "the pipeline wrote no repo.json at " + path);
    var out = new ArrayList<String>();
    objectMapper.readTree(path.toFile()).get("versions").fieldNames().forEachRemaining(out::add);

    return out;
  }

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    downloadedVersions.clear();
    modifiedByVersion.clear();
    keepNewest(false);

    when(sourceArchive.download(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              var version = target.getParent().getFileName().toString();
              downloadedVersions.add(version);
              var bytes =
                  PipelineFixture.controlArchive(
                      "fixture",
                      "fixture-" + version,
                      PipelineFixture.control(version, version),
                      modifiedByVersion.get(version));
              return PipelineFixture.served(target, bytes);
            });
  }

  @Test
  void dropsVersionsWhoseArchiveIsOlderThanTheCutoff() throws Exception {
    archiveModifiedAt("0.1.0", BEFORE_CUTOFF);
    archiveModifiedAt("0.3.0", AFTER_CUTOFF);
    listTags("0.3.0", "0.1.0");

    run();

    assertEquals(List.of("0.3.0"), versionsWritten());
  }

  @Test
  void keepsVersionsWhoseArchiveIsNewerThanTheCutoff() throws Exception {
    archiveModifiedAt("0.1.0", AFTER_CUTOFF);
    archiveModifiedAt("0.3.0", AFTER_CUTOFF);
    listTags("0.3.0", "0.1.0");

    run();

    assertEquals(List.of("0.3.0", "0.1.0"), versionsWritten());
  }

  @Test
  void everyArchiveIsFetchedBeforeTheCutoffCanRejectAny() throws Exception {
    archiveModifiedAt("0.1.0", BEFORE_CUTOFF);
    archiveModifiedAt("0.3.0", AFTER_CUTOFF);
    listTags("0.3.0", "0.1.0");

    run();

    // Every one of them: the cutoff reads bytes that are already on disk.
    assertEquals(List.of("0.1.0", "0.3.0"), downloadedVersions.stream().sorted().toList());
  }

  @Test
  void anExtensionOlderThanTheCutoffIsCataloguedAtItsNewestVersion() throws Exception {
    keepNewest(true);
    archiveModifiedAt("0.1.0", BEFORE_CUTOFF);
    archiveModifiedAt("0.2.0", BEFORE_CUTOFF);
    archiveModifiedAt("0.3.0", BEFORE_CUTOFF);
    listTags("0.3.0", "0.2.0", "0.1.0");

    run();

    assertEquals(List.of("0.3.0"), versionsWritten());
  }

  @Test
  void theSparedVersionIsTheNewestTheRunKnowsOf() throws Exception {
    keepNewest(true);
    PipelineFixture.writeRepoJson(EXTENSION_DIR, STORED_REPO);
    archiveModifiedAt("0.1.0", BEFORE_CUTOFF);
    archiveModifiedAt("0.3.0", BEFORE_CUTOFF);
    listTags("0.3.0", "0.1.0");

    run();

    // 0.9.0 is the newest and is stored already, so the exemption is spent on a version that
    // needed no archive, and no tag reaches the cutoff.
    assertEquals(List.of("0.9.0"), versionsWritten());
  }

  @Test
  void anExtensionOlderThanTheCutoffIsNotCataloguedWithoutKeepNewest() throws Exception {
    archiveModifiedAt("0.1.0", BEFORE_CUTOFF);
    archiveModifiedAt("0.3.0", BEFORE_CUTOFF);
    listTags("0.3.0", "0.1.0");

    run();

    assertFalse(
        Files.exists(PipelineFixture.repoJson(EXTENSION_DIR)),
        "a cutoff that rejects every version leaves nothing to catalogue");
  }
}
