package dev.monogres.monobot.config.output;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/// What a version is, what counts as one when a tag is read, and how two of them compare, which
/// together decide what enters the catalog and in what order.
class VersionTest {
  private static String versionOf(String value) {
    return new Version(value).version();
  }

  // ------------------------------------------------------- the string is the key

  /// Every one of these is a key `build/catalog` holds today. Rewriting any of them to canonical
  /// semver would change the archive it names, because `{version}` reaches `strip_prefix` and
  /// `url` as it stands.
  @ParameterizedTest
  @ValueSource(strings = {"1.2.3", "1.4", "16.11", "18.0", "1beta1", "1.4.0-2", "1.2.3+build.1"})
  void theKeyIsTheStringItWasGiven(String key) {
    assertEquals(key, versionOf(key));
  }

  @Test
  void twoComponentsAreNotFilledOut() {
    assertEquals("1.2", versionOf("1.2"));
  }

  @Test
  void theLeadingVeeIsNotStripped() {
    assertEquals("v1.2.3", versionOf("v1.2.3"));
  }

  @Test
  void onlyBlanksAreNotKeys() {
    assertThrows(IllegalArgumentException.class, () -> new Version(""));
    assertThrows(IllegalArgumentException.class, () -> new Version("  "));
  }

  // ------------------------------------------------- what a tag has to look like

  @Test
  void findAcceptsWhatSemverReads() {
    assertTrue(Version.find("1.2.3").isPresent());
    assertTrue(Version.find("v1.2.3").isPresent());
    assertTrue(Version.find("1.2").isPresent());
    assertTrue(Version.find("1.4.0-2").isPresent());
  }

  /// The string as it stands rather than what the parser made of it: the `replace` rule that
  /// produced it is what spells the key, and the parser only says whether it is a version at all.
  @Test
  void findKeepsTheStringItWasGiven() {
    assertEquals("v1.2", Version.find("v1.2").orElseThrow().version());
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

  /// `1beta1` is pinned by openhalo and reachable no other way. A pin names its key outright, so
  /// nothing asks the parser about it; discovery does ask, and would not find it.
  @Test
  void pinnedKeysNeedNotBeOnesFindWouldAccept() {
    assertEquals("1beta1", versionOf("1beta1"));
    assertTrue(Version.find("1beta1").isEmpty());
  }

  // ----------------------------------------------------------------- ranges

  @Test
  void rangesReadTheKeyAsSemver() {
    assertTrue(new Version("1.2.3").satisfies(">=1.0.0"));
    assertTrue(new Version("1.4").satisfies(">=1.0.0"));
    assertTrue(new Version("1.4.0-2").satisfies(">=1.0.0"));
  }

  /// Reporting it outside every range would drop a version the catalog pins, so a key no parser
  /// reads says so rather than answer.
  @Test
  void rangesRefuseKeysNoParserReads() {
    assertThrows(IllegalArgumentException.class, () -> new Version("1beta1").satisfies(">=1.0.0"));
  }

  // ---------------------------------------------------------------- order and identity

  @Test
  void componentsCompareAsNumbersNotAsText() {
    assertTrue(new Version("1.10.0").compareTo(new Version("1.9.0")) > 0);
    assertTrue(new Version("16.11").compareTo(new Version("16.9")) > 0);
  }

  @Test
  void comparisonIsAscending() {
    var versions = List.of(new Version("1.9.0"), new Version("1.10.0"), new Version("0.1.0"));

    assertEquals(
        List.of("0.1.0", "1.9.0", "1.10.0"),
        versions.stream().sorted().map(Version::version).toList());
  }

  /// Two spellings of the same release are two keys, because they are two archives: `{version}`
  /// reaches `strip_prefix`, so `1.2` and `1.2.0` unpack to different directories.
  @Test
  void versionsThatReadAlikeAreStillDifferentKeys() {
    assertNotEquals(new Version("v1.2.3"), new Version("1.2.3"));
    assertNotEquals(new Version("1.2"), new Version("1.2.0"));
    assertEquals(new Version("1.2.3"), new Version("1.2.3"));
    assertEquals(new Version("1.2.3").hashCode(), new Version("1.2.3").hashCode());
  }

  /// Newest first is what almost every catalog entry carries and what a discovered version is
  /// inserted as, but babelfish reads `4.0` then `5.1`. So the map keeps what it was given and the
  /// caller decides the order, rather than a comparator turning one entry around.
  @Test
  void versionsKeepsTheOrderItWasGiven() {
    var versions = new Versions();
    versions.put(new Version("1.9.0"), null);
    versions.put(new Version("1.10.0"), null);
    versions.put(new Version("0.1.0"), null);

    assertEquals(
        List.of("1.9.0", "1.10.0", "0.1.0"),
        versions.keySet().stream().map(Version::version).toList());
  }
}
