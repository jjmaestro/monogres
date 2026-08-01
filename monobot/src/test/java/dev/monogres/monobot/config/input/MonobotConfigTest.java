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
/// to a null and reach the forge lookup as a NullPointerException with nothing in it naming the
/// file it came from.
class MonobotConfigTest {
  private static final ObjectMapper MAPPER = new ObjectMapper();

  private static MonobotConfig parse(String json) throws Exception {
    return MAPPER.readValue(json, MonobotConfig.class);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "{}",
        "{\"name\": \"envvar\"}",
        "{\"url\": \"https://github.com/theory/pg-envvar\"}",
        "{\"name\": \"\", \"url\": \"https://github.com/theory/pg-envvar\"}",
        "{\"name\": \"  \", \"url\": \"https://github.com/theory/pg-envvar\"}"
      })
  void configMissingWhatItHasToDeclareIsRefused(String json) {
    var failure = assertThrows(Exception.class, () -> parse(json));

    assertTrue(
        rootCauseOf(failure).getMessage().contains("monobot.json declares no"),
        "the failure does not say what is missing: " + rootCauseOf(failure).getMessage());
  }

  @Test
  void configDeclaringBothIsAccepted() throws Exception {
    var config = parse("{\"name\": \"envvar\", \"url\": \"https://github.com/theory/pg-envvar\"}");

    assertEquals("envvar", config.name());
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
