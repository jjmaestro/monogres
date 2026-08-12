package dev.monogres.monobot.catalog;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/// Materialization against the shapes the catalog actually holds. Each source block below is
/// copied from the `build/catalog` entry it is named for, so what these pin is that monobot builds
/// the same URL the Bazel module would, down to the string.
class SourceTemplateTest {
  private static final ObjectMapper MAPPER = new ObjectMapper();

  /// Written as the JSON it is in the catalog, because the order of the properties is what decides
  /// the materialization and a map literal would bury it.
  private static SourceTemplate template(String source, String json) throws IOException {
    var properties = new LinkedHashMap<String, String>();
    MAPPER
        .readTree(json)
        .properties()
        .forEach(property -> properties.put(property.getKey(), property.getValue().asText()));

    return new SourceTemplate(source, properties);
  }

  private static String urlOf(SourceTemplate template, String version, Map<String, String> context)
      throws IOException {
    return template.materialize(version, context).get("url");
  }

  // ---------------------------------------------------------- nothing is owed

  private static SourceTemplate pgvector() throws IOException {
    return template(
        "gh",
        """
        {
          "tag": "v{version}",
          "gh_org": "pgvector",
          "name": "pgvector",
          "filename": "{tag}",
          "strip_prefix": "{name}-{version}",
          "url": "https://github.com/{gh_org}/{name}/archive/refs/tags/{filename}.tar.gz"
        }
        """);
  }

  @Test
  void pgvectorNeedsOnlyTheVersion() throws IOException {
    var materialized = pgvector().materialize("0.8.2", Map.of());

    assertEquals(List.of(), pgvector().unboundNames());
    assertEquals(
        "https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.2.tar.gz",
        materialized.get("url"));
    assertEquals("pgvector-0.8.2", materialized.get("strip_prefix"));
    assertEquals("v0.8.2", materialized.get("tag"));
  }

  /// citus writes the organisation and the name into `url` as well as declaring them. Both spell
  /// the same URL, and the one that is written is the one that counts.
  @Test
  void theUrlMayRepeatWhatTheOtherPropertiesSay() throws IOException {
    var citus =
        template(
            "gh",
            """
            {
              "tag": "v{version}",
              "gh_org": "citusdata",
              "name": "citus",
              "filename": "{tag}",
              "strip_prefix": "{name}-{version}",
              "url": "https://github.com/citusdata/citus/archive/refs/tags/{filename}.tar.gz"
            }
            """);

    assertEquals(
        "https://github.com/citusdata/citus/archive/refs/tags/v14.1.0.tar.gz",
        urlOf(citus, "14.1.0", Map.of()));
  }

  /// postgis is not a forge at all: there is no tag anywhere in the block, and the version alone
  /// spells the tarball.
  @Test
  void sourcesNeedNotBeForges() throws IOException {
    var postgis =
        template(
            "osgeo",
            """
            {
              "name": "postgis",
              "strip_prefix": "{name}-{version}",
              "url": "https://download.osgeo.org/postgis/source/{name}-{version}.tar.gz"
            }
            """);

    assertEquals(List.of(), postgis.unboundNames());
    assertEquals(
        "https://download.osgeo.org/postgis/source/postgis-3.5.7.tar.gz",
        urlOf(postgis, "3.5.7", Map.of()));
  }

  // ------------------------------------------------- what the version context owes

  /// The four ways the catalog spells a tag its versions cannot be read off: the tag itself, an
  /// upstream spelling of the version, a directory name derived from the tag, and a commit where
  /// there is no tag.
  @Test
  void postgresOwesItsTag() throws IOException {
    var postgres =
        template(
            "gh",
            """
            {
              "owner": "postgres",
              "repo": "postgres",
              "filename": "{tag}",
              "url": "https://github.com/{owner}/{repo}/archive/refs/tags/{filename}.tar.gz",
              "strip_prefix": "{repo}-{tag}"
            }
            """);

    assertEquals(List.of("tag"), postgres.unboundNames());

    var materialized = postgres.materialize("18.1", Map.of("tag", "REL_18_1"));
    assertEquals(
        "https://github.com/postgres/postgres/archive/refs/tags/REL_18_1.tar.gz",
        materialized.get("url"));
    assertEquals("postgres-REL_18_1", materialized.get("strip_prefix"));
  }

  @Test
  void wal2jsonOwesTheUpstreamSpellingOfItsVersion() throws IOException {
    var wal2json =
        template(
            "gh",
            """
            {
              "tag": "wal2json_{upstream_version}",
              "gh_org": "eulerto",
              "name": "wal2json",
              "filename": "{tag}",
              "strip_prefix": "{name}-{tag}",
              "url": "https://github.com/{gh_org}/{name}/archive/refs/tags/{filename}.tar.gz"
            }
            """);

    assertEquals(List.of("upstream_version"), wal2json.unboundNames());

    var materialized = wal2json.materialize("2.6.0", Map.of("upstream_version", "2_6"));
    assertEquals(
        "https://github.com/eulerto/wal2json/archive/refs/tags/wal2json_2_6.tar.gz",
        materialized.get("url"));
    assertEquals("wal2json-wal2json_2_6", materialized.get("strip_prefix"));
  }

  /// age tags across a slash, which the archive cannot carry into a directory name, so the block
  /// reads a second spelling of the same tag for the prefix.
  @Test
  void ageOwesItsTagAndTheDirectoryThatTagUnpacksTo() throws IOException {
    var age =
        template(
            "gh",
            """
            {
              "name": "age",
              "strip_prefix": "{name}-{tag_dir}",
              "url": "https://github.com/apache/age/archive/refs/tags/{tag}.tar.gz"
            }
            """);

    assertEquals(List.of("tag_dir", "tag"), age.unboundNames());

    var materialized =
        age.materialize("1.8.0", Map.of("tag", "PG18/v1.8.0-rc0", "tag_dir", "PG18-v1.8.0-rc0"));
    assertEquals(
        "https://github.com/apache/age/archive/refs/tags/PG18/v1.8.0-rc0.tar.gz",
        materialized.get("url"));
    assertEquals("age-PG18-v1.8.0-rc0", materialized.get("strip_prefix"));
  }

  @Test
  void pgjwtOwesTheCommitItIsPinnedTo() throws IOException {
    var pgjwt =
        template(
            "gh",
            """
            {
              "tag": "{commit}",
              "gh_org": "michelp",
              "name": "pgjwt",
              "filename": "{tag}",
              "strip_prefix": "{name}-{commit}",
              "url": "https://github.com/{gh_org}/{name}/archive/{filename}.tar.gz"
            }
            """);

    assertEquals(List.of("commit"), pgjwt.unboundNames());
    assertEquals(
        "https://github.com/michelp/pgjwt/archive/f3d82fd.tar.gz",
        urlOf(pgjwt, "0.2.0", Map.of("commit", "f3d82fd")));
  }

  // ---------------------------------------------------------- the order matters

  /// A property may only read what is defined before it, so the same two properties in the other
  /// order say different things. This is what makes the order of a `sources` block part of the
  /// document.
  @Test
  void propertiesReadOnlyWhatIsDefinedAboveThem() throws IOException {
    var after = template("gh", "{\"tag\": \"v{version}\", \"url\": \"https://x/{tag}\"}");
    var before = template("gh", "{\"url\": \"https://x/{tag}\", \"tag\": \"v{version}\"}");

    assertEquals(List.of(), after.unboundNames());
    assertEquals("https://x/v1.0.0", urlOf(after, "1.0.0", Map.of()));

    assertEquals(List.of("tag"), before.unboundNames());
    assertEquals(
        "https://x/from-the-context", urlOf(before, "1.0.0", Map.of("tag", "from-the-context")));
  }

  // ------------------------------------------------------- what nothing defines

  @Test
  void unknownPlaceholdersNameThemselvesAndTheirProperty() throws IOException {
    var missing = template("gh", "{\"url\": \"https://x/{upstream_version}.tar.gz\"}");

    var thrown =
        assertThrows(IllegalArgumentException.class, () -> missing.materialize("1.0.0", Map.of()));

    assertTrue(thrown.getMessage().contains("gh.url"), thrown.getMessage());
    assertTrue(thrown.getMessage().contains("{upstream_version}"), thrown.getMessage());
  }

  /// Nothing seeds `repo_name`, the one name the reader supplies that monobot cannot.
  @Test
  void repoNameIsNotSeeded() throws IOException {
    var named = template("gh", "{\"url\": \"https://x/{repo_name}.tar.gz\"}");

    assertEquals(List.of("repo_name"), named.unboundNames());
    assertThrows(IllegalArgumentException.class, () -> named.materialize("1.0.0", Map.of()));
  }

  // ------------------------------------------------------------- substitutions

  @Test
  void theVersionAndTheSourceNameAreAlwaysAvailable() throws IOException {
    var both = template("example.com", "{\"url\": \"https://{source}/{version}.tgz\"}");

    assertEquals(List.of(), both.unboundNames());
    assertEquals("https://example.com/1.0.tgz", urlOf(both, "1.0", Map.of()));
  }

  /// A value is substituted as it stands. Regex replacement reads `$` and `\` as syntax, and a
  /// version or a tag may hold either.
  @Test
  void valuesWithRegexPunctuationSubstituteLiterally() throws IOException {
    var punctuated = template("gh", "{\"url\": \"https://x/{tag}\"}");

    assertEquals("https://x/a$1b\\c", urlOf(punctuated, "1.0.0", Map.of("tag", "a$1b\\c")));
  }

  @Test
  void theCatalogPropertiesAreReturnedBesideTheSeed() throws IOException {
    var materialized = pgvector().materialize("0.8.2", Map.of());

    assertEquals("0.8.2", materialized.get("version"));
    assertEquals("gh", materialized.get("source"));
    assertEquals("pgvector", materialized.get("gh_org"));
  }
}
