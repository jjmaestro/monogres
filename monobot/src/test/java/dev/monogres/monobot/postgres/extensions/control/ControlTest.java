package dev.monogres.monobot.postgres.extensions.control;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import org.junit.jupiter.api.Test;

/// The control file grammar, which is the one the Postgres server reads with its own configuration
/// lexer: a `key = value` per line, `#` starting a comment that runs to the end of the line unless
/// it is inside quotes, and a value either bare or single quoted, where `''` is one apostrophe and
/// a backslash escapes the character after it.
///
/// Every value that gets through here is written into `repo.json` and then carried forward by
/// every later run, since the merge only ever adds. A value read wrongly is therefore read wrongly
/// for good.
class ControlTest {
  private static Control control(String text) {
    return Control.fromBytes(text.getBytes(StandardCharsets.UTF_8));
  }

  // ---------------------------------------------------------------- encoding

  /// Control files are UTF-8. Decoded as ISO-8859-1 every non-ASCII character arrives as the two
  /// or more characters its UTF-8 encoding spells.
  @Test
  void nonAsciiIsReadAsUtf8() {
    assertEquals("Añadir café", control("comment = 'Añadir café'").comment());
  }

  // ---------------------------------------------------------------- comments

  @Test
  void trailingCommentIsNotPartOfTheValue() {
    assertEquals("1.0.0", control("default_version = '1.0.0' # what to install").defaultVersion());
  }

  @Test
  void trailingCommentAfterBareValueIsNotPartOfTheValue() {
    assertEquals("extension", control("directory = extension # where it lives").directory());
  }

  @Test
  void wholeLineCommentIsIgnored() {
    assertEquals("1.0.0", control("# a note\ndefault_version = '1.0.0'\n").defaultVersion());
  }

  @Test
  void hashInsideQuotesStartsNoComment() {
    assertEquals("issue #3", control("comment = 'issue #3'").comment());
  }

  // ---------------------------------------------------------------- quoting

  @Test
  void doubledApostropheBecomesOneApostrophe() {
    assertEquals("it's here", control("comment = 'it''s here'").comment());
  }

  /// The same escapes the server's lexer applies, so a value monobot records is the value the
  /// server would have read out of the same file.
  @Test
  void backslashEscapesTheCharacterAfterIt() {
    assertEquals("C:\temp", control("comment = 'C:\\temp'").comment());
    assertEquals("a'b", control("comment = 'a\\'b'").comment());
    assertEquals("a\\b", control("comment = 'a\\\\b'").comment());
    assertEquals("aXb", control("comment = 'a\\Xb'").comment());
  }

  @Test
  void unterminatedStringIsRejected() {
    var failure = assertThrows(RuntimeException.class, () -> control("comment = '"));

    assertTrue(
        failure.getMessage().contains("comment"),
        "the failure does not name the directive: " + failure.getMessage());
  }

  @Test
  void emptyStringIsAnEmptyValue() {
    assertEquals("", control("comment = ''").comment());
  }

  // ---------------------------------------------------------------- values

  @Test
  void bareValuesNeedNoQuotes() {
    var control = control("default_version = 1.2.3\nrelocatable = true\nsuperuser = false\n");

    assertEquals("1.2.3", control.defaultVersion());
    assertEquals(Boolean.TRUE, control.relocatable());
    assertEquals(Boolean.FALSE, control.superuser());
  }

  @Test
  void listValuesAreSplitOnCommas() {
    assertArrayEquals(
        new String[] {"plpgsql", "hstore"}, control("requires = 'plpgsql, hstore'").requires());
  }

  /// Postgres adds control directives from release to release, and an archive is read once and
  /// catalogued forever. A directive this record does not model is still something the upstream
  /// declared about that version, so it is carried rather than refused.
  @Test
  void unmodelledDirectivesAreCarried() {
    var control = control("default_version = '1.0.0'\nnew_directive = 'yes'\n");

    assertEquals("1.0.0", control.defaultVersion());
    assertEquals(Map.of("new_directive", "yes"), control.extra());
  }

  @Test
  void controlWithNoUnmodelledDirectivesCarriesNothing() {
    assertEquals(Map.of(), control("default_version = '1.0.0'").extra());
  }

  @Test
  void noRelocateIsSplitOnCommasToo() {
    assertArrayEquals(new String[] {"plpgsql"}, control("no_relocate = 'plpgsql'").noRelocate());
  }

  @Test
  void listValuesTolerateTheSpacingAroundTheCommas() {
    assertArrayEquals(new String[] {"a", "b", "c"}, control("requires = ' a ,b,  c '").requires());
  }

  @Test
  void declaringNoListLeavesItUnset() {
    assertNull(control("default_version = '1.0.0'").requires());
  }

  // ---------------------------------------------------------------- invariants

  /// The one Postgres invariant this record enforces: `schema` names the schema an extension is
  /// loaded into, and an extension that can be moved between schemas cannot have one.
  @Test
  void schemaIsRefusedForRelocatableExtensions() {
    assertThrows(RuntimeException.class, () -> control("relocatable = true\nschema = 'public'\n"));
  }

  @Test
  void schemaIsAcceptedForNonRelocatableExtensions() {
    assertEquals("public", control("relocatable = false\nschema = 'public'\n").schema());
    assertEquals("public", control("schema = 'public'").schema());
  }

  @Test
  void defaultsApplyToWhatIsNotDeclared() {
    var control = control("default_version = '1.0.0'");

    assertEquals(Boolean.TRUE, control.superuser());
    assertEquals(Boolean.FALSE, control.trusted());
    assertEquals(Boolean.FALSE, control.relocatable());
  }
}
