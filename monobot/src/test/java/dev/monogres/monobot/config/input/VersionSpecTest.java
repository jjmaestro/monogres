package dev.monogres.monobot.config.input;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonMappingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.output.Version;
import java.time.Instant;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;

/// How a tag name becomes the string a version is read from, which of the versions are kept, and
/// which `versions` blocks are rejected rather than accepted and left doing nothing.
class VersionSpecTest {
  private static final String CONFIG_TEMPLATE =
      """
      {
        "name": "fixture",
        "url": "https://github.com/monogres/fixture",
        "versions": %s
      }
      """;

  private static VersionSpec spec(String... regexAndReplacement) {
    var replace = new TagReplacement[regexAndReplacement.length / 2];
    for (var i = 0; i < replace.length; i++) {
      replace[i] =
          new TagReplacement(
              Pattern.compile(regexAndReplacement[2 * i]), regexAndReplacement[2 * i + 1]);
    }

    return new VersionSpec(replace, null, null, false);
  }

  private static VersionSpec satisfying(String range) {
    return new VersionSpec(null, range, null, false);
  }

  private static MonobotConfig configWith(String versionsJson) throws Exception {
    return new ObjectMapper()
        .readValue(CONFIG_TEMPLATE.formatted(versionsJson), MonobotConfig.class);
  }

  private static void assertRejected(String versionsJson) {
    var thrown = assertThrows(JsonMappingException.class, () -> configWith(versionsJson));

    assertTrue(
        thrown.getCause() instanceof IllegalArgumentException,
        "expected the constructor's own complaint, got " + thrown.getCause());
  }

  // ---------------------------------------------------------------- rewriting

  @Test
  void oneRuleRewritesTheTagItMatches() {
    assertEquals("1.2.3", spec("REL([0-9]+)_([0-9]+)_([0-9]+)", "$1.$2.$3").rewrite("REL1_2_3"));
  }

  @Test
  void tagNoRuleMatchesIsLeftAsItIs() {
    assertEquals(
        "release-1.2.3",
        spec("REL([0-9]+)_([0-9]+)_([0-9]+)", "$1.$2.$3").rewrite("release-1.2.3"));
  }

  @Test
  void theFirstMatchingRuleIsTheOneThatApplies() {
    var spec = spec("REL_([0-9]+)_([0-9]+)_([0-9]+)", "$1.$2.$3", "REL_(.*)", "$1");

    assertEquals("1.2.3", spec.rewrite("REL_1_2_3"));
    assertEquals("4.5.6", spec.rewrite("REL_4.5.6"));
  }

  @Test
  void rulesDoNotChain() {
    // The second rule matches what the first produced and still does not run. One rule handles a
    // tag, rather than every rule in turn.
    var spec = spec("REL(.*)", "$1", "(.*)", "$1-suffix");

    assertEquals("1.2.3", spec.rewrite("REL1.2.3"));
  }

  @Test
  void theRegexHasToMatchTheWholeTag() {
    // A substring match would let a rule for `REL(.*)` fire on `preREL1.2.3` and produce something
    // the tag never said.
    assertEquals("preREL1.2.3", spec("REL(.*)", "$1").rewrite("preREL1.2.3"));
  }

  @Test
  void patternMatchingTheEmptyTailSubstitutesOnce() {
    // `(.*)` matches the whole tag and then the empty string after it, so a substitution that
    // rescanned would append the replacement twice.
    assertEquals("1.2.3!", spec("(.*)", "$1!").rewrite("1.2.3"));
  }

  @Test
  void rulesNeedNotCaptureAnything() {
    assertEquals("2.4", spec("master_tag", "2.4").rewrite("master_tag"));
  }

  @Test
  void theSpecWithNoRulesRewritesNothing() {
    assertEquals("v1.2.3", new VersionSpec().rewrite("v1.2.3"));
  }

  // ---------------------------------------------------------------- selecting

  @Test
  void everyVersionIsKeptWhenThereIsNoRange() {
    assertTrue(new VersionSpec().satisfiedBy(new Version("0.0.1")));
  }

  @Test
  void theRangeDecidesWhichVersionsAreKept() {
    var spec = satisfying(">=1.0.0 <2.0.0");

    assertTrue(spec.satisfiedBy(new Version("1.5.0")));
    assertFalse(spec.satisfiedBy(new Version("0.9.0")));
    assertFalse(spec.satisfiedBy(new Version("2.0.0")));
  }

  @Test
  void anExclusionIsWrittenAsWhatSurroundsIt() {
    // node-semver has no negation, so what is dropped is stated as what is kept around it.
    var spec = satisfying("<1.0.0 || >1.9.9");

    assertTrue(spec.satisfiedBy(new Version("0.9.0")));
    assertFalse(spec.satisfiedBy(new Version("1.5.0")));
    assertTrue(spec.satisfiedBy(new Version("2.0.0")));
  }

  @Test
  void packagingRevisionsAreInsideTheRangeOfTheirRelease() {
    // In node a pre-release is a candidate for a release and ranges leave it out. Here 1.4.0-2 is
    // the second packaging of 1.4.0, and a range that dropped it would drop most of sslutils.
    assertTrue(satisfying(">=1.0.0").satisfiedBy(new Version("1.4.0-2")));
  }

  @Test
  void theCutoffIsReadAsAnInstant() {
    var spec = new VersionSpec(null, null, "2020-01-01T00:00:00Z", true);

    assertEquals(Instant.parse("2020-01-01T00:00:00Z"), spec.cutoff().orElseThrow());
    assertTrue(spec.keepNewest());
  }

  @Test
  void thereIsNoCutoffUnlessOneIsGiven() {
    var spec = new VersionSpec();

    assertTrue(spec.cutoff().isEmpty());
    assertFalse(spec.keepNewest());
  }

  // ---------------------------------------------------------------- rejected

  @Test
  void repeatedRegexIsRejected() {
    assertThrows(
        IllegalArgumentException.class,
        () -> spec("REL(.*)", "$1", "REL(.*)", "$1-something-else"));
  }

  @Test
  void rangeNoVersionCouldSatisfyIsRejected() {
    // The library reads this as a range with nothing in it, which keeps no version at all, so a
    // typo would empty the catalog in silence.
    assertThrows(IllegalArgumentException.class, () -> satisfying("not a range"));
    assertRejected(
        """
        {"satisfy": "not a range"}
        """);
  }

  @Test
  void emptyRangeIsRejected() {
    // This one is read as >=0.0.0, so it keeps everything and says nothing.
    assertThrows(IllegalArgumentException.class, () -> satisfying(""));
  }

  @Test
  void cutoffThatIsNotAnInstantIsRejected() {
    assertThrows(
        IllegalArgumentException.class, () -> new VersionSpec(null, null, "2020-01-01", false));
  }

  @Test
  void keepNewestWithNothingToSpareItFromIsRejected() {
    assertThrows(
        IllegalArgumentException.class, () -> new VersionSpec(null, ">=1.0.0", null, true));
  }

  // ---------------------------------------------------------------- through Jackson

  @Test
  void rulesAreReadAsPairsAndKeepTheOrderTheyAreWrittenIn() throws Exception {
    var monobotConfig =
        configWith(
            """
            {"replace": [["REL_([0-9]+)_([0-9]+)_([0-9]+)", "$1.$2.$3"], ["REL_(.*)", "$1"]]}
            """);

    assertEquals("1.2.3", monobotConfig.versionSpec().rewrite("REL_1_2_3"));
    assertEquals("4.5.6", monobotConfig.versionSpec().rewrite("REL_4.5.6"));
  }

  @Test
  void theSelectionIsReadFromTheBlockToo() throws Exception {
    var versionSpec =
        configWith(
                """
                {"satisfy": ">=1.0.0 <2.0.0", "after": "2020-01-01T00:00:00Z", "keepNewest": true}
                """)
            .versionSpec();

    assertTrue(versionSpec.satisfiedBy(new Version("1.5.0")));
    assertFalse(versionSpec.satisfiedBy(new Version("2.0.0")));
    assertEquals(Instant.parse("2020-01-01T00:00:00Z"), versionSpec.cutoff().orElseThrow());
    assertTrue(versionSpec.keepNewest());
  }

  @Test
  void theEmptyBlockRewritesNothingAndKeepsEverything() throws Exception {
    var versionSpec = configWith("{}").versionSpec();

    assertEquals("v1.2.3", versionSpec.rewrite("v1.2.3"));
    assertTrue(versionSpec.satisfiedBy(new Version("0.0.1")));
    assertTrue(versionSpec.cutoff().isEmpty());
  }

  @Test
  void ruleThatIsNotPairedFailsToParse() {
    assertRejected(
        """
        {"replace": [["REL(.*)"]]}
        """);
    assertRejected(
        """
        {"replace": [["REL(.*)", "$1", "extra"]]}
        """);
    assertRejected(
        """
        {"replace": [[]]}
        """);
    assertRejected(
        """
        {"replace": [[null, "$1"]]}
        """);
  }

  @Test
  void regexThatDoesNotCompileFailsToParse() {
    assertRejected(
        """
        {"replace": [["REL(", "$1"]]}
        """);
  }

  @Test
  void theRuleHasNoSecondShape() {
    // A record's canonical constructor is a creator whether or not anything asks for it, so without
    // FromPair the object below would bind by component name: two ways to write one rule.
    assertRejected(
        """
        {"replace": [{"regex": "REL(.*)", "replacement": "$1"}]}
        """);
    assertRejected(
        """
        {"replace": ["REL(.*)"]}
        """);
  }

  @Test
  void anAbsentBlockGivesTheSpecThatRewritesNothingAndKeepsEverything() throws Exception {
    var json =
        """
        {
          "name": "fixture",
          "url": "https://github.com/monogres/fixture"
        }
        """;

    var versionSpec = new ObjectMapper().readValue(json, MonobotConfig.class).versionSpec();

    assertEquals("v1.2.3", versionSpec.rewrite("v1.2.3"));
    assertTrue(versionSpec.satisfiedBy(new Version("0.0.1")));
    assertTrue(versionSpec.cutoff().isEmpty());
  }
}
