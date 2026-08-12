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
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// The previous output is an input: a run reads the repo.json it wrote last time and merges into
/// it. Two behaviours are entangled in that one read, preserving what is stored and choosing what
/// to fetch next, and these separate them.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchIncrementalTest {
  private static final String EXTENSION_DIR = "extensions/fixture";

  private static final String CONFIG =
      """
      {
        "name": "fixture",
        "url": "https://github.com/monogres/fixture",
        "versions": { "replace": [["^v(.*)$", "$1"]] }
      }
      """;

  private static final String SEEDED_SHA256 =
      "1111111111111111111111111111111111111111111111111111111111111111";

  private static final String STORED_VERSION =
      """
      "%s" : {
        "tag" : "v%s",
        "sha256" : "%s",
        "strip_prefix" : "seeded-prefix-%s",
        "commit" : "%s",
        "short_commit" : "ignored"
      }
      """;

  private static final String STORED_REPO =
      """
      {
        "sources" : {
          "github.com" : {
            "url" : "https://api.github.com/repos/monogres/fixture/tarball/{commit}",
            "type" : "tar.gz"
          }
        },
        "versions" : { %s },
        "metadata" : {
          "compatible_with" : { "0.1.0" : ">=12" }
        },
        "version" : 1
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  private final List<String> downloadedCommits = new ArrayList<>();

  private static String storedVersion(String version) {
    var commit = PipelineFixture.commitSha("aa" + version.charAt(2));
    return STORED_VERSION.formatted(version, version, SEEDED_SHA256, version, commit);
  }

  private static void seed(String... versions) throws IOException {
    PipelineFixture.writeRepoJson(
        EXTENSION_DIR,
        STORED_REPO.formatted(
            String.join(
                ",",
                java.util.Arrays.stream(versions)
                    .map(FetchIncrementalTest::storedVersion)
                    .toList())));
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  private com.fasterxml.jackson.databind.JsonNode written() throws IOException {
    var path = PipelineFixture.repoJson(EXTENSION_DIR);
    assertTrue(Files.exists(path), "the pipeline wrote no repo.json at " + path);
    return objectMapper.readTree(path.toFile());
  }

  private List<String> versionsWritten() throws IOException {
    var out = new ArrayList<String>();
    written().get("versions").fieldNames().forEachRemaining(out::add);
    return out;
  }

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    downloadedCommits.clear();
    PipelineFixture.writeConfig(EXTENSION_DIR, CONFIG);

    when(tagLister.getTags(any()))
        .thenReturn(
            new GitTag[] {
              new GitTag("v0.3.0", PipelineFixture.objectId("aa3")),
              new GitTag("v0.2.0", PipelineFixture.objectId("aa2")),
              new GitTag("v0.1.0", PipelineFixture.objectId("aa1"))
            });

    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              var commit = target.getFileName().toString().replace(".tar.gz", "");
              downloadedCommits.add(commit);
              var version = "0." + commit.charAt(2) + ".0";
              var bytes =
                  PipelineFixture.controlArchive(
                      "fixture",
                      "fixture-" + commit,
                      PipelineFixture.control(version, "fetched " + version),
                      0L);
              Files.createDirectories(target.getParent());
              Files.write(target, bytes);
              return Future.succeededFuture(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
            });
  }

  @Test
  void seedingTheOldestVersionStillCollectsTheNewerOnes() throws Exception {
    seed("0.1.0");

    run();

    assertEquals(List.of("0.3.0", "0.2.0", "0.1.0"), versionsWritten());
  }

  @Test
  void seedingTheNewestVersionStillCollectsTheOlderOnes() throws Exception {
    seed("0.3.0");

    run();

    assertEquals(List.of("0.3.0", "0.2.0", "0.1.0"), versionsWritten());
  }

  @Test
  void versionMissingFromTheMiddleIsCollectedAgain() throws Exception {
    seed("0.1.0", "0.3.0");

    run();

    assertEquals(List.of("0.3.0", "0.2.0", "0.1.0"), versionsWritten());
    assertEquals(
        List.of(PipelineFixture.commitSha("aa2")),
        downloadedCommits,
        "only the missing version is worth downloading");
  }

  @Test
  void nothingIsDownloadedWhenEveryVersionIsAlreadyStored() throws Exception {
    seed("0.1.0", "0.2.0", "0.3.0");

    run();

    assertEquals(List.of(), downloadedCommits);
    assertEquals(List.of("0.3.0", "0.2.0", "0.1.0"), versionsWritten());
  }

  @Test
  void storedVersionsKeepWhatWasRecordedForThem() throws Exception {
    seed("0.1.0");

    run();

    var stored = written().get("versions").get("0.1.0");
    assertEquals(SEEDED_SHA256, stored.get("sha256").asText());
    assertEquals("seeded-prefix-0.1.0", stored.get("strip_prefix").asText());
  }

  @Test
  void storedMetadataSurvivesAlongsideWhatTheRunExtracts() throws Exception {
    seed("0.1.0");

    run();

    var metadata = written().get("metadata");
    assertEquals(">=12", metadata.get("compatible_with").get("0.1.0").asText());
    assertEquals("fetched 0.3.0", metadata.get(".control").get("0.3.0").get("comment").asText());
  }
}
