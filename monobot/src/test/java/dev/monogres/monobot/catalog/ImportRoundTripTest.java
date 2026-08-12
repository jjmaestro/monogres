package dev.monogres.monobot.catalog;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.input.MonobotConfig;
import dev.monogres.monobot.config.output.RepoConfig;
import dev.monogres.monobot.config.output.VersionContext;
import dev.monogres.monobot.config.output.Versions;
import dev.monogres.monobot.json.CatalogPrinter;
import dev.monogres.monobot.json.ConfigObjectMapperCustomizer;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/// A committed `repo.json` imported to a `monobot.json` and generated back has to be the same
/// bytes.
///
/// This is what makes `import` usable to bootstrap a catalog written by hand: the derivation is
/// lossless or it is worthless. Everything the entry decided has to survive the trip, and what has
/// to survive it is nearly all of the document, since the only two things monobot derives are the
/// digest and the version context the templates read.
///
/// The digests are put back rather than computed, because that is the only half of this a network
/// answers for. What is under test is whether the rest came through.
class ImportRoundTripTest {
  private static ObjectMapper configuredMapper() {
    var mapper = new ObjectMapper();
    new ConfigObjectMapperCustomizer().customize(mapper);

    return mapper;
  }

  private static String committed(String entry) throws IOException {
    var path = "corpus/" + entry + "/repo.json";
    try (InputStream in = ImportRoundTripTest.class.getClassLoader().getResourceAsStream(path)) {
      assertNotNull(in, path + " is missing from the test resources");

      return new String(in.readAllBytes(), StandardCharsets.UTF_8);
    }
  }

  private static String imported(ObjectMapper mapper, String entry, String document)
      throws IOException {
    return CatalogPrinter.print(
        mapper.valueToTree(Import.documentOf(entry, mapper.readValue(document, RepoConfig.class))));
  }

  /// The catalog a generate run would write from an imported config, with the digests the entry
  /// already recorded put back where the run would have computed them.
  ///
  /// The merge is the one an all-pinned entry gets: every version in the order it is pinned. That
  /// is what [dev.monogres.monobot.fetch.Fetch] does with pins, and every entry `import` produces
  /// is all pins.
  private static String generated(ObjectMapper mapper, String monobotJson, RepoConfig recorded)
      throws IOException {
    var config = mapper.readValue(monobotJson, MonobotConfig.class);
    var versions = new Versions();

    config
        .versionsSpec()
        .pin()
        .forEach(
            (version, context) ->
                versions.put(
                    version,
                    new VersionContext(
                        new LinkedHashMap<>(context),
                        recorded.getVersions().get(version).sha256())));

    return CatalogPrinter.print(
        mapper.valueToTree(new RepoConfig(config.sources(), versions, config.metadata())));
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
  void everyCatalogEntryImportsAndGeneratesBackUnchanged(String entry) throws IOException {
    var mapper = configuredMapper();
    var committed = committed(entry);
    var monobotJson = imported(mapper, entry, committed);

    assertEquals(
        committed, generated(mapper, monobotJson, mapper.readValue(committed, RepoConfig.class)));
  }

  /// The version key reaches the pin as the document spells it. `sslutils` is `1.4` and normalizing
  /// it to `1.4.0` would name `sslutils-1.4.0`, which is a 404.
  @Test
  void versionKeysReachThePinAsTheyAreWritten() throws IOException {
    var mapper = configuredMapper();

    assertTrue(
        imported(mapper, "sslutils", committed("sslutils")).contains("\"1.4\""),
        "the pinned key was rewritten");
  }

  /// Nothing owes its sources anything here, so the pins are a list, which is the shape that says
  /// the least about an entry that has nothing more to say.
  @Test
  void pinsThatOweNothingBecomePlainLists() throws IOException {
    var mapper = configuredMapper();

    assertTrue(
        imported(mapper, "pgvector", committed("pgvector")).contains("\"pin\": [\"0.8.2\"]"),
        imported(mapper, "pgvector", committed("pgvector")));
  }

  /// A version that owes its sources a `tag` cannot be a bare string, so those entries get the map,
  /// and what is in it is the version context minus the digest monobot computes.
  @Test
  void pinsThatOweSomethingCarryItAndNotTheDigest() throws IOException {
    var mapper = configuredMapper();
    var monobotJson = imported(mapper, "age", committed("age"));

    assertTrue(monobotJson.contains("\"tag\": \"PG18/v1.8.0-rc0\""), monobotJson);
    assertTrue(monobotJson.contains("\"tag_dir\":"), monobotJson);
    assertFalse(monobotJson.contains("sha256"), "the digest was pinned: " + monobotJson);
  }

  /// The repository only a `discover` block would read, taken from the two ways the catalog spells
  /// a GitHub one. postgis spells neither: its tarballs come from download.osgeo.org, and guessing
  /// would put a plausible URL pointing at nothing into the file.
  @Test
  void theRepositoryIsInferredWhereTheSourceNamesOne() throws IOException {
    var mapper = configuredMapper();

    assertTrue(
        imported(mapper, "pgvector", committed("pgvector"))
            .contains("\"url\": \"https://github.com/pgvector/pgvector\""),
        "the repository was not read out of the source");
    assertEquals(
        Optional.empty(),
        Import.repositoryUrl(
            mapper
                .readValue(committed("postgis"), RepoConfig.class)
                .getSources()
                .firstEntry()
                .getValue()),
        "a repository was invented for a source that names none");
  }
}
