package dev.monogres.monobot.config.input;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/// What `monobot.json` has to declare. Nothing else checks: there is no nullability module and no
/// bean validation extension on the classpath, so a config missing one of these would deserialize
/// to a null and reach the materializer as a NullPointerException with nothing in it naming the
/// file it came from.
class MonobotConfigTest {
  private static final ObjectMapper MAPPER = new ObjectMapper();

  private static MonobotConfig parse(String json) throws Exception {
    return MAPPER.readValue(json, MonobotConfig.class);
  }

  private static final String SOURCES =
      "\"sources\": {\"gh\": {\"url\": \"https://x/{version}.tar.gz\"}}";

  private static final String PIN = "\"versions\": {\"pin\": [\"1.0.0\"]}";

  /// Without a source there is no archive to name, so there is nothing an entry could be.
  @ParameterizedTest
  @ValueSource(strings = {"{}", "{\"name\": \"envvar\"}", "{\"sources\": {}}"})
  void configDeclaringNoSourceIsRefused(String json) {
    var failure = assertThrows(Exception.class, () -> parse(json));

    assertTrue(
        rootCauseOf(failure).getMessage().contains("declares no sources"),
        "the failure does not say what is missing: " + rootCauseOf(failure).getMessage());
  }

  /// Naming neither a pinned version nor a way to discover one leaves an entry that would write a
  /// document with the formulas for building download URLs and no version to build one for.
  @Test
  void configNamingNoVersionAtAllIsRefused() {
    var failure = assertThrows(Exception.class, () -> parse("{" + SOURCES + "}"));

    assertTrue(
        rootCauseOf(failure).getMessage().contains("pins no version and discovers none"),
        rootCauseOf(failure).getMessage());
  }

  /// Only discovery reads the repository, so only discovery needs it named.
  @Test
  void discoveringVersionsWithoutRepositoryUrlIsRefused() {
    var failure =
        assertThrows(
            Exception.class, () -> parse("{" + SOURCES + ", \"versions\": {\"discover\": {}}}"));

    assertTrue(
        rootCauseOf(failure).getMessage().contains("no url to list them from"),
        rootCauseOf(failure).getMessage());
  }

  @Test
  void pinnedEntriesNeedNeitherNameNorUrl() throws Exception {
    var config = parse("{" + SOURCES + ", " + PIN + "}");

    assertTrue(config.controlStem().isEmpty());
    assertEquals(null, config.repoUrl());
    assertEquals(1, config.versionsSpec().pin().size());
  }

  @Test
  void theNameIsTheControlStemAndTheUrlTheRepository() throws Exception {
    var config =
        parse(
            "{\"name\": \"envvar\", \"url\": \"https://github.com/theory/pg-envvar\", "
                + SOURCES
                + ", "
                + PIN
                + "}");

    assertEquals("envvar", config.controlStem().orElseThrow());
    assertEquals(URI.create("https://github.com/theory/pg-envvar").toURL(), config.repoUrl());
  }

  private static Throwable rootCauseOf(Throwable failure) {
    var cause = failure;
    while (cause.getCause() != null) {
      cause = cause.getCause();
    }

    return cause;
  }
}
