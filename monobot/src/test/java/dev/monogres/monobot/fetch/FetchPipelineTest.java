package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.output.RepoConfig;
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

  /// The archive's single top-level directory, written as a literal rather than materialized from
  /// the `sources` block that predicts it: a fixture built from the formula agrees with the
  /// formula whatever the formula says.
  private static final String STRIP_PREFIX = "fixture-1.2.3";

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

  /// Version to the archive it names, so the [SourceArchive] stand-in can serve whichever version
  /// the pipeline asks for. The spool is addressed by version, so the directory the path is in
  /// is what says which one.
  private final Map<String, byte[]> archivesByVersion = new HashMap<>();

  private final List<Path> downloaded = new ArrayList<>();

  private static String golden() throws IOException {
    try (InputStream in = FetchPipelineTest.class.getClassLoader().getResourceAsStream(GOLDEN)) {
      assertNotNull(in, GOLDEN + " is missing from the test resources");
      return new String(in.readAllBytes(), StandardCharsets.UTF_8).stripTrailing();
    }
  }

  private void serve(String extension, String version) throws IOException {
    archivesByVersion.put(
        version,
        PipelineFixture.controlArchive(
            extension, extension + "-" + version, PipelineFixture.control(version, version), 0L));
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

  /// The versions the run wrote a control file for, which live beside the entry rather than in it,
  /// put back into the order the entry lists its versions in.
  private List<String> controlVersionsIn(String relativeDir) throws IOException {
    var into = PipelineFixture.repoJson(relativeDir).getParent().resolve("metadata");
    var written = new ArrayList<String>();
    try (var entries = Files.list(into)) {
      entries
          .filter(version -> Files.exists(version.resolve("control.json")))
          .forEach(version -> written.add(version.getFileName().toString()));
    }
    var order = versionsIn(relativeDir);
    written.sort((left, right) -> Integer.compare(order.indexOf(left), order.indexOf(right)));

    return written;
  }

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    archivesByVersion.clear();
    downloaded.clear();

    // Stands in for the download: writes the archive the caller asked for where it asked for it
    // and returns the digest of those bytes, which is what the real implementation does.
    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              downloaded.add(target);
              var version = target.getParent().getFileName().toString();
              var bytes = archivesByVersion.get(version);
              assertNotNull(bytes, "no archive registered for version " + version);
              Files.createDirectories(target.getParent());
              Files.write(target, bytes);
              return Future.succeededFuture(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
            });
  }

  @Test
  void writesTheGoldenRepoJson() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture"));
    archivesByVersion.put(
        "1.2.3", PipelineFixture.archive(STRIP_PREFIX + "/fixture.control", CONTROL, 0L));
    tags(new GitTag("v1.2.3", PipelineFixture.objectId(COMMIT)));

    run();

    var written = PipelineFixture.repoJson("extensions/fixture");
    assertTrue(Files.exists(written), "the pipeline wrote no repo.json at " + written);
    assertEquals(golden(), Files.readString(written).stripTrailing());
  }

  /// `strip_prefix` is a template in the `sources` block rather than a value per version, so the
  /// document carries a formula. Materializing it for the version that was fetched and comparing
  /// that against the directory the archive really holds is what says the formula is right, and
  /// nothing else in the pipeline compares the two.
  @Test
  void theStripPrefixMaterializesToTheArchiveTopLevelDirectory() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture"));
    archivesByVersion.put(
        "1.2.3", PipelineFixture.archive(STRIP_PREFIX + "/fixture.control", CONTROL, 0L));
    tags(new GitTag("v1.2.3", PipelineFixture.objectId(COMMIT)));

    run();

    var written =
        objectMapper.readValue(
            PipelineFixture.repoJson("extensions/fixture").toFile(), RepoConfig.class);
    var predicted =
        written
            .getSources()
            .templates()
            .getFirst()
            .materialize("1.2.3", Map.of())
            .get("strip_prefix");

    assertEquals(1, downloaded.size(), "the run fetched something other than the one tag");
    assertEquals(
        PipelineFixture.rootDirectoryOf(downloaded.get(0)),
        predicted,
        "the strip prefix the document spells is not the directory the archive carries");
  }

  @Test
  void collectsEveryVersionInOneRunNewestFirst() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture"));
    for (var version : List.of("0.1.0", "0.2.0", "0.3.0")) {
      serve("fixture", version);
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
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture"));
    serve("fixture", "1.2.3");
    tags(
        new GitTag("v1.2.3", PipelineFixture.objectId("aa3")),
        new GitTag("vlatest", PipelineFixture.objectId("bb1")),
        new GitTag("nightly", PipelineFixture.objectId("bb2")));

    run();

    assertEquals(List.of("1.2.3"), versionsIn("extensions/fixture"));
    assertEquals(1, downloaded.size(), "a rejected tag must not be downloaded");
  }

  @Test
  void twoDigitComponentsOrderNumericallyRatherThanAsText() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture"));
    for (var version : List.of("1.2.0", "1.9.0", "1.10.0")) {
      serve("fixture", version);
    }
    tags(
        new GitTag("v1.2.0", PipelineFixture.objectId("ca2")),
        new GitTag("v1.9.0", PipelineFixture.objectId("ca9")),
        new GitTag("v1.10.0", PipelineFixture.objectId("cb0")));

    run();

    var expected = List.of("1.10.0", "1.9.0", "1.2.0");
    assertEquals(expected, versionsIn("extensions/fixture"));
    assertEquals(expected, controlVersionsIn("extensions/fixture"));
  }

  @Test
  void scansEveryExtensionItFinds() throws Exception {
    PipelineFixture.writeConfig("extensions/alpha", CONFIG.formatted("alpha"));
    PipelineFixture.writeConfig("extensions/beta", CONFIG.formatted("beta"));
    serve("alpha", "1.0.0");
    serve("beta", "2.0.0");
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
          "sources": { "gh": { "url": "https://x/{version}.tar.gz" } },
          "versions": { "discover": { "replace": [["^v(.*)$", "$1"]] } },
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

  /// An archive carrying neither a control file nor PGXN metadata is still an archive with a
  /// digest, and the digest is what `repo.json` is for. What it carried is written beside it, so
  /// carrying nothing costs those files and not the entry.
  @Test
  void anArchiveCarryingNoMetadataIsStillCatalogued() throws Exception {
    PipelineFixture.writeConfig("extensions/fixture", CONFIG.formatted("fixture"));
    archivesByVersion.put(
        "1.2.3", PipelineFixture.archive("fixture-1.2.3/README.md", "nothing to see", 0L));
    tags(new GitTag("v1.2.3", PipelineFixture.objectId("aa3")));

    run();

    assertEquals(List.of("1.2.3"), versionsIn("extensions/fixture"));
    assertFalse(
        Files.exists(
            PipelineFixture.repoJson("extensions/fixture")
                .getParent()
                .resolve("metadata/1.2.3/control.json")),
        "an archive with no control file must leave no control.json behind");
  }
}
