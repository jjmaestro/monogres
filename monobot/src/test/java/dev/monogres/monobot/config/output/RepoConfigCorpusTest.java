package dev.monogres.monobot.config.output;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.json.CatalogPrinter;
import dev.monogres.monobot.json.ConfigObjectMapperCustomizer;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/// A committed `repo.json` read into the model and written back has to be the same bytes.
///
/// This is the whole output contract in one assertion, and it holds the model to documents nobody
/// wrote for it: the top-level order, a `sources` block whose property order decides which archive
/// it names, a version context whose keys differ per entry, a `metadata` block that is somebody
/// else's schema entirely, and the layout over all of it. Anything the model drops, renames,
/// reorders or normalises shows up here as a diff.
///
/// The entries are copies, because monobot is its own Bazel module and a glob cannot reach
/// `build/catalog`. They cover every shape the catalog has: a version context that is a bare
/// sha256 and ones that owe `upstream_version`, `tag` with `tag_dir`, or a `commit`; a source that
/// is not a forge; a `metadata` block with arrays of objects in it. The catalog itself is held to
/// the same contract by regenerating it and diffing.
class RepoConfigCorpusTest {
  private static final List<String> ENTRIES =
      List.of(
          "age",
          "hll",
          "noset",
          "pg_graphql",
          "pg_qualstats",
          "pg_stat_monitor",
          "pgjwt",
          "pgvector",
          "postgis",
          "sslutils");

  private static ObjectMapper configuredMapper() {
    var mapper = new ObjectMapper();
    new ConfigObjectMapperCustomizer().customize(mapper);

    return mapper;
  }

  private static String committed(String entry) throws IOException {
    var path = "corpus/" + entry + "/repo.json";
    try (InputStream in = RepoConfigCorpusTest.class.getClassLoader().getResourceAsStream(path)) {
      assertNotNull(in, path + " is missing from the test resources");

      return new String(in.readAllBytes(), StandardCharsets.UTF_8);
    }
  }

  private static String reemitted(String document) throws IOException {
    var mapper = configuredMapper();

    return CatalogPrinter.print(mapper.valueToTree(mapper.readValue(document, RepoConfig.class)));
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "age",
        "hll",
        "noset",
        "pg_graphql",
        "pg_qualstats",
        "pg_stat_monitor",
        "pgjwt",
        "pgvector",
        "postgis",
        "sslutils",
      })
  void catalogEntriesReadAndWriteBackUnchanged(String entry) throws IOException {
    var committed = committed(entry);

    assertEquals(committed, reemitted(committed));
  }

  /// Jackson caches the serializer it builds for a type, so one serialization can only ever
  /// observe one property order. Re-introspecting with a fresh mapper is what makes an unstable
  /// order observable at all.
  @Test
  void propertyOrderDoesNotDependOnIntrospectionOrder() throws IOException {
    var committed = committed("pgvector");

    for (var attempt = 0; attempt < 20; attempt++) {
      assertEquals(committed, reemitted(committed));
    }
  }

  /// The version context is a map because what it holds is per entry, so a spot check that the
  /// entries between them cover more than a bare digest.
  @Test
  void theCorpusCoversTheVersionContextsTheCatalogHolds() throws IOException {
    var mapper = configuredMapper();
    var keys =
        ENTRIES.stream()
            .flatMap(
                entry -> {
                  try {
                    return mapper
                        .readValue(committed(entry), RepoConfig.class)
                        .getVersions()
                        .values()
                        .stream();
                  } catch (IOException e) {
                    throw new AssertionError(e);
                  }
                })
            .flatMap(context -> context.keySet().stream())
            .distinct()
            .toList();

    assertTrue(keys.contains(VersionContext.SHA256), keys.toString());
    assertTrue(keys.contains("tag"), keys.toString());
    assertTrue(keys.contains("tag_dir"), keys.toString());
    assertTrue(keys.contains("upstream_version"), keys.toString());
    assertTrue(keys.contains("commit"), keys.toString());
  }
}
