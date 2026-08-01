package dev.monogres.monobot.postgres.extensions.control;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/// The Postgres extension control file grammar, which is the one the server reads it with: the
/// same configuration lexer it reads `postgresql.conf` with.
///
/// A line is `key = value`, the `=` optional. `#` starts a comment that runs to the end of the
/// line unless it falls inside a quoted string. A value is either bare, ending at the first
/// whitespace or `#`, or single quoted, where `''` is one apostrophe and a backslash escapes the
/// character after it: `b`, `f`, `n`, `r` and `t` name control characters, one to three octal
/// digits name a byte, and anything else stands for itself. A quoted value does not span lines.
///
/// Control files are UTF-8. Nothing here decodes anything else, because whatever this reads is
/// written into `repo.json` and the merge only ever adds, so a value read wrongly stays wrong.
final class ControlParser {
  private static final char COMMENT = '#';
  private static final char ASSIGN = '=';
  private static final char QUOTE = '\'';
  private static final char ESCAPE = '\\';

  private static final char FIRST_OCTAL_DIGIT = '0';
  private static final char LAST_OCTAL_DIGIT = '7';
  private static final int OCTAL_RADIX = 8;
  private static final int MAX_OCTAL_DIGITS = 3;

  private ControlParser() {}

  static Map<String, String> parse(byte[] bytes) {
    var directives = new LinkedHashMap<String, String>();

    for (var line : new String(bytes, StandardCharsets.UTF_8).split("\\R")) {
      parseLine(line, directives);
    }

    return directives;
  }

  private static void parseLine(String line, Map<String, String> directives) {
    var cursor = skipBlanks(line, 0);
    if (cursor == line.length() || line.charAt(cursor) == COMMENT) {
      return;
    }

    var keyEnd = cursor;
    while (keyEnd < line.length()
        && !Character.isWhitespace(line.charAt(keyEnd))
        && line.charAt(keyEnd) != ASSIGN) {
      keyEnd++;
    }
    var key = line.substring(cursor, keyEnd);

    cursor = skipBlanks(line, keyEnd);
    if (cursor < line.length() && line.charAt(cursor) == ASSIGN) {
      cursor = skipBlanks(line, cursor + 1);
    }

    directives.put(
        key,
        cursor < line.length() && line.charAt(cursor) == QUOTE
            ? quotedValue(key, line, cursor)
            : bareValue(line, cursor));
  }

  private static int skipBlanks(String line, int from) {
    var cursor = from;
    while (cursor < line.length() && Character.isWhitespace(line.charAt(cursor))) {
      cursor++;
    }

    return cursor;
  }

  private static String bareValue(String line, int from) {
    var end = from;
    while (end < line.length()
        && !Character.isWhitespace(line.charAt(end))
        && line.charAt(end) != COMMENT) {
      end++;
    }

    return line.substring(from, end);
  }

  private static String quotedValue(String key, String line, int from) {
    var value = new StringBuilder();
    var cursor = from + 1;

    while (cursor < line.length()) {
      var character = line.charAt(cursor);

      if (character == QUOTE) {
        if (cursor + 1 < line.length() && line.charAt(cursor + 1) == QUOTE) {
          value.append(QUOTE);
          cursor += 2;
          continue;
        }

        return value.toString();
      }

      if (character == ESCAPE && cursor + 1 < line.length()) {
        cursor = appendEscaped(value, line, cursor + 1);
        continue;
      }

      value.append(character);
      cursor++;
    }

    throw new IllegalArgumentException("Unterminated quoted value for " + key + ": " + line);
  }

  private static int appendEscaped(StringBuilder value, String line, int at) {
    var escaped = line.charAt(at);

    switch (escaped) {
      case 'b' -> value.append('\b');
      case 'f' -> value.append('\f');
      case 'n' -> value.append('\n');
      case 'r' -> value.append('\r');
      case 't' -> value.append('\t');
      default -> {
        if (escaped >= FIRST_OCTAL_DIGIT && escaped <= LAST_OCTAL_DIGIT) {
          return appendOctal(value, line, at);
        }
        value.append(escaped);
      }
    }

    return at + 1;
  }

  private static int appendOctal(StringBuilder value, String line, int at) {
    var octal = 0;
    var digits = 0;

    while (digits < MAX_OCTAL_DIGITS
        && at + digits < line.length()
        && line.charAt(at + digits) >= FIRST_OCTAL_DIGIT
        && line.charAt(at + digits) <= LAST_OCTAL_DIGIT) {
      octal = octal * OCTAL_RADIX + (line.charAt(at + digits) - FIRST_OCTAL_DIGIT);
      digits++;
    }
    value.append((char) octal);

    return at + digits;
  }
}
