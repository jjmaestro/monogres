package dev.monogres.monobot.json;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/// Where the printer breaks a line, which is the whole of what it decides. Every case is written
/// as the compact document going in and the laid out document coming out, so the expectation is
/// the layout itself rather than a description of it.
class CatalogPrinterTest {
  private static final ObjectMapper MAPPER = new ObjectMapper();

  private static String printed(String compact) throws IOException {
    return CatalogPrinter.print(MAPPER.readTree(compact));
  }

  // ------------------------------------------------------------------ objects

  @Test
  void anObjectIsAlwaysBroken() throws IOException {
    assertEquals("{\n  \"a\": 1\n}\n", printed("{\"a\":1}"));
  }

  @Test
  void nestedObjectsIndentTwoColumnsEach() throws IOException {
    assertEquals(
        """
        {
          "a": {
            "b": {
              "c": true
            }
          }
        }
        """,
        printed("{\"a\":{\"b\":{\"c\":true}}}"));
  }

  @Test
  void anEmptyObjectStaysOnItsLine() throws IOException {
    assertEquals("{\n  \"a\": {}\n}\n", printed("{\"a\":{}}"));
  }

  // ------------------------------------------------------------------- arrays

  @Test
  void anArrayOfScalarsThatFitsStaysOnOneLine() throws IOException {
    assertEquals("{\n  \"a\": [1, 2, 3]\n}\n", printed("{\"a\":[1,2,3]}"));
  }

  @Test
  void anEmptyArrayStaysOnItsLine() throws IOException {
    assertEquals("{\n  \"a\": []\n}\n", printed("{\"a\":[]}"));
  }

  /// An array holding a container is broken however short it is. Inlining it would put the
  /// container on one line, and a container does not go on one line.
  @Test
  void anArrayHoldingAnObjectIsBrokenEvenWhenItWouldFit() throws IOException {
    assertEquals(
        """
        {
          "a": [
            {
              "b": 1
            }
          ]
        }
        """,
        printed("{\"a\":[{\"b\":1}]}"));
  }

  @Test
  void anArrayHoldingAnArrayIsBrokenEvenWhenItWouldFit() throws IOException {
    assertEquals("{\n  \"a\": [\n    [1, 2]\n  ]\n}\n", printed("{\"a\":[[1,2]]}"));
  }

  // -------------------------------------------------------------- where 80 is

  /// One array whose single element is padded until the line it renders to ends exactly on
  /// `width`, returned as that line. The assertions then read the decision off the output rather
  /// than restate the arithmetic.
  private static String arrayLineOfWidth(int width) throws IOException {
    var overhead = "  \"a\": [\"\"]".length();
    var document = "{\"a\":[\"" + "x".repeat(width - overhead) + "\"]}";

    return printed(document).lines().skip(1).findFirst().orElseThrow();
  }

  @Test
  void anArrayEndingOnColumn80StaysOnOneLine() throws IOException {
    var line = arrayLineOfWidth(CatalogPrinter.MAX_WIDTH);

    assertEquals(CatalogPrinter.MAX_WIDTH, line.length());
    assertTrue(line.endsWith("\"]"), line);
  }

  @Test
  void anArrayEndingOnColumn81IsBroken() throws IOException {
    assertEquals("  \"a\": [", arrayLineOfWidth(CatalogPrinter.MAX_WIDTH + 1));
  }

  /// The width is measured from where the value starts, so the same array breaks or not depending
  /// on how deep it sits and how long the key in front of it is.
  @Test
  void theKeyAndTheIndentCountTowardsTheWidth() throws IOException {
    var elements = "\"aaaaaaaaaa\", \"bbbbbbbbbb\", \"cccccccccc\", \"dddddddddd\"";
    var shallow = printed("{\"k\":[" + elements + "]}");
    var deep = printed("{\"outer\":{\"a-much-longer-key\":[" + elements + "]}}");

    assertTrue(shallow.contains("\"k\": [\"aaaaaaaaaa\","), shallow);
    assertTrue(deep.contains("\"a-much-longer-key\": [\n"), deep);
  }

  // ------------------------------------------------------------------ scalars

  @ParameterizedTest
  @ValueSource(strings = {"null", "true", "false", "1", "-2.5", "\"\"", "\"text\""})
  void scalarsAreWrittenTheWayJsonSpellsThem(String scalar) throws IOException {
    assertEquals("{\n  \"a\": " + scalar + "\n}\n", printed("{\"a\":" + scalar + "}"));
  }

  @Test
  void keysAndValuesEscapeAlike() throws IOException {
    assertEquals("{\n  \"a\\\"b\": \"c\\\"d\"\n}\n", printed("{\"a\\\"b\": \"c\\\"d\"}"));
  }

  // -------------------------------------------------------------- the document

  @Test
  void theDocumentEndsWithOneNewline() throws IOException {
    var printed = printed("{\"a\":1}");

    assertTrue(printed.endsWith("}\n"), printed);
    assertEquals(printed.stripTrailing() + "\n", printed);
  }

  /// Round trip, so the layout cannot change what the document says.
  @Test
  void theLaidOutDocumentParsesBackToWhatWentIn() throws IOException {
    var compact =
        "{\"v\":1,\"s\":{\"gh\":{\"tag\":\"v{version}\",\"url\":\"https://x/{tag}\"}},"
            + "\"a\":[1,[2,3],{\"b\":null}],\"e\":{},\"f\":[]}";

    assertEquals(MAPPER.readTree(compact), MAPPER.readTree(printed(compact)));
  }
}
