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
import java.io.InputStream;
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

/// Drives the whole pipeline, Scan through Fetch to the written repo.json, with the two network
/// calls replaced: [TagLister] returns fixed tags and [SourceArchive] writes a generated archive
/// instead of downloading one. Everything between them is the real code, including the tag
/// rewriting, the version selection and the .control extraction.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchPipelineTest {
  private static final String GOLDEN = "golden/pipeline-repo.json";
  private static final String COMMIT = "8cf409d1b669e0e3e22fa79bb54027a4b555e822";

  /// The archive's single top-level directory: what GitHub serves for this org, name and commit.
  /// A literal rather than a call to the [dev.monogres.monobot.git.Repo] that predicts it, because
  /// a fixture built from the formula agrees with the formula whatever the formula says.
  private static final String STRIP_PREFIX = "monogres-fixture-8cf409d";

  /// The bytes the golden's sha256 was computed from. Kept verbatim rather than built from
  /// [PipelineFixture#control] so a change to the helper cannot quietly move the digest.
  private static final String CONTROL =
      """
      default_version = '1.2.3'
      comment = 'a fixture extension'
      relocatable = false
      """;

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

  /// Commit to the archive it names, so the [SourceArchive] stand-in can serve whichever version
  /// the pipeline asks for. The path it is handed carries the commit and nothing else.
  private final Map<String, byte[]> archivesByCommit = new HashMap<>();

  private final List<Path> downloaded = new ArrayList<>();

  private static String golden() throws IOException {
    try (InputStream in = FetchPipelineTest.class.getClassLoader().getResourceAsStream(GOLDEN)) {
      assertNotNull(in, GOLDEN + " is missing from the test resources");
      return new String(in.readAllBytes(), StandardCharsets.UTF_8).stripTrailing();
    }
  }

  private void serve(String extension, String version, String commit) throws IOException {
    archivesByCommit.put(
        commit,
        PipelineFixture.controlArchive(
            extension, extension + "-" + commit, PipelineFixture.control(version, version), 0L));
  }

  private void tags(GitTag... gitTags) throws Exception {
    when(tagLister.getTags(any())).thenReturn(gitTags);
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  private List<String> versionsIn(String relativeDir) throws IOException {
    var tree = objectMapper.readTree(PipelineFixture.repoJson(relativeDir).toFile());
    var out = new ArrayList<String>();
    tree.get("versions").fieldNames().forEachRemaining(out::add);
    return out;
  }

  private List<String> metadataKeysIn(String relativeDir, String category) throws IOException {
    var tree = objectMapper.readTree(PipelineFixture.repoJson(relativeDir).toFile());
    var out = new ArrayList<String>();
    tree.get("metadata").get(category).fieldNames().forEachRemaining(out::add);
    return out;
  }

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    archivesByCommit.clear();
    downloaded.clear();

    // Stands in for the download: writes the archive the caller asked for where it asked for it
    // and returns the digest of those bytes, which is what the real implementation does.
    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              downloaded.add(target);
              var commit = target.getFileName().toString().replace(".tar.gz", "");
              var bytes = archivesByCommit.get(commit);
              assertNotNull(bytes, "no archive registered for commit " + commit);
              Files.createDirectories(target.getParent());
              Files.write(target, bytes);
              return Future.succeededFuture(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
            });
  }

  @Test
  void writesTheGoldenRepoJson() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture", "fixture"));
    archivesByCommit.put(
        COMMIT, PipelineFixture.archive(STRIP_PREFIX + "/fixture.control", CONTROL, 0L));
    tags(new GitTag("v1.2.3", PipelineFixture.objectId(COMMIT)));

    run();

    var written = PipelineFixture.repoJson("extensions/fixture");
    assertTrue(Files.exists(written), "the pipeline wrote no repo.json at " + written);
    assertEquals(golden(), Files.readString(written).stripTrailing());
  }

  /// `strip_prefix` is a prediction about the archive a forge serves, and nothing else compares it
  /// against one: the formula is asserted elsewhere against itself. The fixture archive really
  /// carries the directory GitHub would have served for this org, name and commit, written as a
  /// literal, so a formula that stopped agreeing with it shows up here.
  @Test
  void theStripPrefixIsTheArchiveTopLevelDirectory() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture", "fixture"));
    archivesByCommit.put(
        COMMIT, PipelineFixture.archive(STRIP_PREFIX + "/fixture.control", CONTROL, 0L));
    tags(new GitTag("v1.2.3", PipelineFixture.objectId(COMMIT)));

    run();

    var predicted =
        objectMapper
            .readTree(PipelineFixture.repoJson("extensions/fixture").toFile())
            .get("versions")
            .get("1.2.3")
            .get("strip_prefix")
            .asText();

    assertEquals(1, downloaded.size(), "the run fetched something other than the one tag");
    assertEquals(
        PipelineFixture.rootDirectoryOf(downloaded.get(0)),
        predicted,
        "the strip prefix the run recorded is not the directory the archive actually carries");
  }

  @Test
  void collectsEveryVersionInOneRunNewestFirst() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture", "fixture"));
    for (var version : List.of("0.1.0", "0.2.0", "0.3.0")) {
      serve("fixture", version, PipelineFixture.commitSha("aa" + version.charAt(2)));
    }
    tags(
        new GitTag("v0.3.0", PipelineFixture.objectId("aa3")),
        new GitTag("v0.2.0", PipelineFixture.objectId("aa2")),
        new GitTag("v0.1.0", PipelineFixture.objectId("aa1")));

    run();

    assertEquals(List.of("0.3.0", "0.2.0", "0.1.0"), versionsIn("extensions/fixture"));
  }

  @Test
  void rejectsTagsThatAreNotSemver() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture", "fixture"));
    serve("fixture", "1.2.3", PipelineFixture.commitSha("aa3"));
    tags(
        new GitTag("v1.2.3", PipelineFixture.objectId("aa3")),
        new GitTag("vlatest", PipelineFixture.objectId("bb1")),
        new GitTag("nightly", PipelineFixture.objectId("bb2")));

    run();

    assertEquals(List.of("1.2.3"), versionsIn("extensions/fixture"));
    assertEquals(1, downloaded.size(), "a rejected tag must not be downloaded");
  }

  @Test
  void twoDigitComponentsOrderTheSameInVersionsAndMetadata() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture", "fixture"));
    for (var seed : List.of("ca2", "ca9", "cb0")) {
      serve("fixture", "1.0.0", PipelineFixture.commitSha(seed));
    }
    tags(
        new GitTag("v1.2.0", PipelineFixture.objectId("ca2")),
        new GitTag("v1.9.0", PipelineFixture.objectId("ca9")),
        new GitTag("v1.10.0", PipelineFixture.objectId("cb0")));

    run();

    var expected = List.of("1.10.0", "1.9.0", "1.2.0");
    assertEquals(expected, versionsIn("extensions/fixture"));
    assertEquals(expected, metadataKeysIn("extensions/fixture", ".control"));
  }

  @Test
  void scansEveryExtensionItFinds() throws Exception {
    PipelineFixture.writeConfig("extensions/alpha", CONFIG.formatted("alpha", "alpha"));
    PipelineFixture.writeConfig("extensions/beta", CONFIG.formatted("beta", "beta"));
    serve("alpha", "1.0.0", PipelineFixture.commitSha("a1"));
    serve("beta", "2.0.0", PipelineFixture.commitSha("b1"));
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
    assertEquals(List.of("2.0.0"), versionsIn("extensions/beta"));
  }

  @Test
  void skipsDisabledExtensionsEntirely() throws Exception {
    PipelineFixture.writeConfig(
        "extensions/fixture",
        """
        {
          "name": "fixture",
          "url": "https://github.com/monogres/fixture",
          "disabled": true
        }
        """);
    tags(new GitTag("v1.2.3", PipelineFixture.objectId("aa3")));

    run();

    assertFalse(
        Files.exists(PipelineFixture.repoJson("extensions/fixture")),
        "a disabled extension must produce no repo.json");
    assertTrue(downloaded.isEmpty(), "a disabled extension must download nothing");
  }

  @Test
  void writesNothingWhenNoArchiveCarriesMetadata() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture", "fixture"));
    archivesByCommit.put(
        PipelineFixture.commitSha("aa3"),
        PipelineFixture.archive("fixture-aa3/README.md", "nothing to see", 0L));
    tags(new GitTag("v1.2.3", PipelineFixture.objectId("aa3")));

    run();

    assertFalse(
        Files.exists(PipelineFixture.repoJson("extensions/fixture")),
        "an archive with neither META.json nor a control file must produce no repo.json");
  }
}
