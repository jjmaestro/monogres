package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.JsonNode;
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
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// The two files an archive can answer for, and the four combinations of them. A PGXN distribution
/// ships a `META.json`, a plain PGXS extension ships a `{name}.control`, plenty ship both, and an
/// archive that ships neither is a version the catalog has nothing to say about.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchMetadataTest {
  private static final String EXTENSION_DIR = "extensions/fixture";
  private static final String STRIP_PREFIX = "monogres-fixture-aa1";

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
        "versions": { "discover": { "replace": [["^v(.*)$", "$1"]] } }
      }
      """;

  private static final String CONTROL =
      """
      default_version = '1.0.0'
      comment = 'a fixture extension'
      requires = 'plpgsql, hstore'
      """;

  private static final String META_JSON =
      """
      {
        "name": "fixture",
        "abstract": "a fixture extension",
        "version": "1.0.0",
        "maintainer": "nobody <nobody@example.com>",
        "license": "postgresql",
        "provides": {"fixture": {"file": "fixture.sql", "version": "1.0.0"}},
        "meta-spec": {"version": "1.0.0"}
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  private final Map<String, byte[]> archivesByVersion = new HashMap<>();

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    archivesByVersion.clear();
    PipelineFixture.writeConfig(EXTENSION_DIR, CONFIG);

    when(tagLister.getTags(any()))
        .thenReturn(new GitTag[] {new GitTag("v1.0.0", PipelineFixture.objectId("aa1"))});

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

  private void serve(Map<String, String> entries) throws IOException {
    archivesByVersion.put("1.0.0", PipelineFixture.archive(entries, 0L));
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  private static Map<String, String> entries(String... namesAndBodies) {
    var entries = new LinkedHashMap<String, String>();
    for (var at = 0; at < namesAndBodies.length; at += 2) {
      entries.put(STRIP_PREFIX + "/" + namesAndBodies[at], namesAndBodies[at + 1]);
    }

    return entries;
  }

  /// The files the run wrote beside the entry for this version, which is where what an archive
  /// carried goes now that `repo.json` is an index of archives rather than of their contents.
  private List<String> extractedFiles() throws IOException {
    var into = PipelineFixture.repoJson(EXTENSION_DIR).getParent().resolve("metadata/1.0.0");
    if (!Files.isDirectory(into)) {
      return List.of();
    }
    try (var files = Files.list(into)) {
      return files.map(file -> file.getFileName().toString()).sorted().toList();
    }
  }

  private JsonNode extracted(String filename) throws IOException {
    return objectMapper.readTree(
        PipelineFixture.repoJson(EXTENSION_DIR)
            .getParent()
            .resolve("metadata/1.0.0")
            .resolve(filename)
            .toFile());
  }

  @Test
  void controlFileAloneIsCatalogued() throws Exception {
    serve(entries("fixture.control", CONTROL));

    run();

    assertEquals(List.of("control.json"), extractedFiles());
    assertEquals("a fixture extension", extracted("control.json").get("comment").asText());
  }

  /// The PGXN branch. A distribution that ships only a META.json is catalogued from it, verbatim.
  @Test
  void metaJsonAloneIsCatalogued() throws Exception {
    serve(entries("META.json", META_JSON));

    run();

    assertEquals(List.of("META.json"), extractedFiles());
    assertEquals("postgresql", extracted("META.json").get("license").asText());
    assertEquals("1.0.0", extracted("META.json").get("meta-spec").get("version").asText());
  }

  @Test
  void bothAreCataloguedSideBySide() throws Exception {
    serve(entries("META.json", META_JSON, "fixture.control", CONTROL));

    run();

    assertEquals(List.of("META.json", "control.json"), extractedFiles());
    assertEquals("a fixture extension", extracted("control.json").get("comment").asText());
    assertEquals("postgresql", extracted("META.json").get("license").asText());
  }

  /// An archive carrying neither is still an archive with a digest, and the digest is what
  /// `repo.json` is for. What an archive carried is written beside the entry, so carrying nothing
  /// costs those files and not the entry.
  @Test
  void neitherStillLeavesTheVersionInTheCatalog() throws Exception {
    serve(entries("README.md", "nothing here"));

    run();

    assertTrue(
        Files.exists(PipelineFixture.repoJson(EXTENSION_DIR)),
        "a version whose archive says nothing about it is still a version");
    assertEquals(List.of(), extractedFiles());
  }

  /// `requires` is a comma-separated list in the file and an array in the catalog, which is the
  /// one control field with a deserializer of its own.
  @Test
  void listValuedControlFieldsReachTheCatalogAsArrays() throws Exception {
    serve(entries("fixture.control", CONTROL));

    run();

    var requires = extracted("control.json").get("requires");
    assertTrue(requires.isArray(), "requires reached the catalog as " + requires.getNodeType());
    assertEquals(
        List.of("plpgsql", "hstore"), List.of(requires.get(0).asText(), requires.get(1).asText()));
  }

  /// The catalog gets what the parsers made of these files and the cache gets the files, so a
  /// question about the parsing has something to be settled against. The control file goes in
  /// under the stem it was found by, which is the extension's own name.
  @Test
  void theCacheKeepsBothFilesAsTheArchiveSpelledThem() throws Exception {
    serve(entries("META.json", META_JSON, "fixture.control", CONTROL));

    run();

    var cached = PipelineFixture.cached(EXTENSION_DIR, "1.0.0");
    assertEquals(CONTROL, Files.readString(cached.resolve("fixture.control")));
    assertEquals(META_JSON, Files.readString(cached.resolve("META.json")));
  }
}
