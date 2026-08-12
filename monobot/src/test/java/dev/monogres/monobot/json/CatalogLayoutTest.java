package dev.monogres.monobot.json;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/// The layout rule against the documents it was read off. Each of these is a copy of a
/// `build/catalog` entry, and reading one and writing it back has to return the same bytes.
///
/// Copies, because monobot is its own Bazel module and a glob cannot reach the catalog. They are
/// chosen for what they exercise rather than to be a sample: `pg_qualstats` holds the longest
/// array the catalog keeps on one line and `pg_stat_monitor` the shortest it breaks, which is the
/// pair that decides where the width is; `pgvector` has an array of objects beside a broken array
/// of strings; `sslutils` nests four deep; `pg_graphql` is the largest entry that is laid out this
/// way. The catalog itself is held to the rule by regenerating it and diffing.
class CatalogLayoutTest {
  private static final ObjectMapper MAPPER = new ObjectMapper();

  private static String resource(String path) throws IOException {
    try (InputStream in = CatalogLayoutTest.class.getClassLoader().getResourceAsStream(path)) {
      assertNotNull(in, path + " is missing from the test resources");

      return new String(in.readAllBytes(), StandardCharsets.UTF_8);
    }
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
  void catalogEntriesAreWrittenBackUnchanged(String entry) throws IOException {
    var committed = resource("corpus/" + entry + "/repo.json");

    assertEquals(committed, CatalogPrinter.print(MAPPER.readTree(committed)));
  }
}
