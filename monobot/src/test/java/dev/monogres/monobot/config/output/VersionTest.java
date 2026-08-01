package dev.monogres.monobot.config.output;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;

/// What counts as a version and how two of them compare, which together decide what enters the
/// catalog and in what order.
class VersionTest {
  private static String versionOf(String value) {
    return new Version(value).version();
  }

  // ---------------------------------------------------------------- what parses

  @Test
  void threeComponentsParse() {
    assertEquals("1.2.3", versionOf("1.2.3"));
  }

  @Test
  void theParserReadsPastTheVprefix() {
    assertEquals("1.2.3", versionOf("v1.2.3"));
  }

  @Test
  void theMissingPatchComponentIsFilledIn() {
    assertEquals("1.2.0", versionOf("1.2"));
    assertEquals("1.2.0", versionOf("v1.2"));
  }

  @Test
  void preReleaseAndBuildMetadataSurvive() {
    assertEquals("1.4.0-2", versionOf("1.4.0-2"));
    assertEquals("1.2.3+build.1", versionOf("1.2.3+build.1"));
  }

  @Test
  void twoComponentsWithPreReleaseDoNotParse() {
    // The filled-in patch is appended, which gives 1.4-2.0, and semver puts the patch before the
    // pre-release. Extensions tagging this way need a replace rule to reach 1.4.0-2.
    assertTrue(Version.find("1.4-2").isEmpty());
  }

  @Test
  void tagsNamingNoVersionAreNotCoerced() {
    // Coercion would read each of these as 1.0.0, or as nothing at all, and either way the catalog
    // would gain an entry whose key came from nowhere in the tag.
    assertTrue(Version.find("REL1_2_3").isEmpty());
    assertTrue(Version.find("master_tag").isEmpty());
    assertTrue(Version.find("").isEmpty());
  }

  @Test
  void constructingFromSomethingElseFails() {
    assertThrows(IllegalArgumentException.class, () -> new Version("master_tag"));
  }

  // ---------------------------------------------------------------- order and identity

  @Test
  void componentsCompareAsNumbersNotAsText() {
    assertTrue(new Version("1.10.0").compareTo(new Version("1.9.0")) > 0);
  }

  @Test
  void comparisonIsAscending() {
    var versions = List.of(new Version("1.9.0"), new Version("1.10.0"), new Version("0.1.0"));

    assertEquals(
        List.of("0.1.0", "1.9.0", "1.10.0"),
        versions.stream().sorted().map(Version::version).toList());
  }

  @Test
  void versionsThatParseAlikeAreOneKey() {
    assertEquals(new Version("v1.2.3"), new Version("1.2.3"));
    assertEquals(new Version("1.2"), new Version("1.2.0"));
    assertEquals(new Version("1.2.3").hashCode(), new Version("v1.2.3").hashCode());
    assertNotEquals(new Version("1.2.3"), new Version("1.2.4"));
  }

  @Test
  void versionsIsNewestFirst() {
    var versions = new Versions();
    versions.put(new Version("1.9.0"), null);
    versions.put(new Version("1.10.0"), null);
    versions.put(new Version("0.1.0"), null);

    assertEquals(
        List.of("1.10.0", "1.9.0", "0.1.0"),
        versions.keySet().stream().map(Version::version).toList());
  }
}
