package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.JsonNode;
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
        "url": "https://github.com/monogres/fixture"
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

  private final Map<String, byte[]> archivesByCommit = new HashMap<>();

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    archivesByCommit.clear();
    PipelineFixture.writeConfig(EXTENSION_DIR, CONFIG);

    when(tagLister.getTags(any()))
        .thenReturn(new GitTag[] {new GitTag("v1.0.0", PipelineFixture.objectId("aa1"))});

    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              var commit = target.getFileName().toString().replace(".tar.gz", "");
              var bytes = archivesByCommit.get(commit);
              assertNotNull(bytes, "no archive registered for commit " + commit);
              Files.createDirectories(target.getParent());
              Files.write(target, bytes);
              return Future.succeededFuture(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
            });
  }

  private void serve(Map<String, String> entries) throws IOException {
    archivesByCommit.put(PipelineFixture.commitSha("aa1"), PipelineFixture.archive(entries, 0L));
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

  private List<String> metadataCategories() throws IOException {
    var out = new ArrayList<String>();
    objectMapper
        .readTree(PipelineFixture.repoJson(EXTENSION_DIR).toFile())
        .get("metadata")
        .fieldNames()
        .forEachRemaining(out::add);

    return out;
  }

  private JsonNode metadata(String category) throws IOException {
    return objectMapper
        .readTree(PipelineFixture.repoJson(EXTENSION_DIR).toFile())
        .get("metadata")
        .get(category)
        .get("1.0.0");
  }

  @Test
  void controlFileAloneIsCatalogued() throws Exception {
    serve(entries("fixture.control", CONTROL));

    run();

    assertEquals(List.of(".control"), metadataCategories());
    assertEquals("a fixture extension", metadata(".control").get("comment").asText());
  }

  /// The PGXN branch. A distribution that ships only a META.json is catalogued from it, verbatim.
  @Test
  void metaJsonAloneIsCatalogued() throws Exception {
    serve(entries("META.json", META_JSON));

    run();

    assertEquals(List.of("META.json"), metadataCategories());
    assertEquals("postgresql", metadata("META.json").get("license").asText());
    assertEquals("1.0.0", metadata("META.json").get("meta-spec").get("version").asText());
  }

  @Test
  void bothAreCataloguedSideBySide() throws Exception {
    serve(entries("META.json", META_JSON, "fixture.control", CONTROL));

    run();

    assertEquals(List.of(".control", "META.json"), metadataCategories());
    assertEquals("a fixture extension", metadata(".control").get("comment").asText());
    assertEquals("postgresql", metadata("META.json").get("license").asText());
  }

  @Test
  void neitherLeavesTheExtensionOutOfTheCatalog() throws Exception {
    serve(entries("README.md", "nothing here"));

    run();

    assertFalse(
        Files.exists(PipelineFixture.repoJson(EXTENSION_DIR)),
        "a version the archive says nothing about is not a catalog entry");
  }

  /// `requires` is a comma-separated list in the file and an array in the catalog, which is the
  /// one control field with a deserializer of its own.
  @Test
  void listValuedControlFieldsReachTheCatalogAsArrays() throws Exception {
    serve(entries("fixture.control", CONTROL));

    run();

    var requires = metadata(".control").get("requires");
    assertTrue(requires.isArray(), "requires reached the catalog as " + requires.getNodeType());
    assertEquals(
        List.of("plpgsql", "hstore"), List.of(requires.get(0).asText(), requires.get(1).asText()));
  }
}
