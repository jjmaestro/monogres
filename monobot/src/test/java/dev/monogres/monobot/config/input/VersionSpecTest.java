package dev.monogres.monobot.config.input;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonMappingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;

/// How a tag name becomes the string a version is read from, and which `versions` blocks are
/// rejected rather than accepted and left doing nothing.
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

    return new VersionSpec(replace);
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

  // ---------------------------------------------------------------- rejected

  @Test
  void repeatedRegexIsRejected() {
    assertThrows(
        IllegalArgumentException.class,
        () -> spec("REL(.*)", "$1", "REL(.*)", "$1-something-else"));
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
  void theEmptyBlockRewritesNothing() throws Exception {
    assertEquals("v1.2.3", configWith("{}").versionSpec().rewrite("v1.2.3"));
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
  void anAbsentBlockGivesTheSpecThatRewritesNothing() throws Exception {
    var json =
        """
        {
          "name": "fixture",
          "url": "https://github.com/monogres/fixture"
        }
        """;

    var monobotConfig = new ObjectMapper().readValue(json, MonobotConfig.class);

    assertEquals("v1.2.3", monobotConfig.versionSpec().rewrite("v1.2.3"));
  }
}
