package dev.monogres.monobot.json;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.TextNode;

/// Lays a catalog document out the way the catalog is written: two-space indent, LF, a trailing
/// newline, and one rule deciding every line break.
///
/// An object is always broken over lines. An array of scalars is kept on one line while that line
/// ends at or before [#MAX_WIDTH], and broken one element per line once it does not. An array
/// holding an object or another array is always broken, because the alternative is an object on
/// one line and objects do not go on one line.
///
/// Jackson cannot express this. A `PrettyPrinter` is called as the generator walks the value and
/// is told what it is about to write, never what is left, so nothing there can break on the width
/// of a subtree it has not reached yet. The document is built as a tree and written here instead,
/// with the mapper's own indentation off.
///
/// The width is measured over the line without the comma that separates it from the next one. The
/// catalog pins it no closer than somewhere in 74 to 80, those being the longest line it keeps and
/// one less than the shortest it breaks; 80 is what the rest of the repository is written to.
public class CatalogPrinter {
  static final int MAX_WIDTH = 80;

  private static final int INDENT = 2;
  private static final String KEY_SEPARATOR = ": ";
  private static final String ELEMENT_SEPARATOR = ", ";

  public static String print(JsonNode document) {
    var out = new StringBuilder();
    writeValue(document, 0, 0, out);

    return out.append('\n').toString();
  }

  /// The subtree on one line. This is the measurement rather than the output: [#writeValue] is
  /// what decides whether the line it would produce is one this document may carry.
  private static String oneLine(JsonNode node) {
    if (!node.isContainerNode()) {
      return node.toString();
    }

    var joined = new StringBuilder(node.isObject() ? "{" : "[");
    if (node.isObject()) {
      for (var field : node.properties()) {
        joined
            .append(joined.length() > 1 ? ELEMENT_SEPARATOR : "")
            .append(quoted(field.getKey()))
            .append(KEY_SEPARATOR)
            .append(oneLine(field.getValue()));
      }
    } else {
      for (var element : node) {
        joined.append(joined.length() > 1 ? ELEMENT_SEPARATOR : "").append(oneLine(element));
      }
    }

    return joined.append(node.isObject() ? "}" : "]").toString();
  }

  /// Quoted and escaped by the same code that writes the values, so a key and a string value
  /// spell a character the same way.
  private static String quoted(String key) {
    return TextNode.valueOf(key).toString();
  }

  private static boolean holdsOnlyScalars(JsonNode array) {
    for (var element : array) {
      if (element.isContainerNode()) {
        return false;
      }
    }

    return true;
  }

  /// `column` is where the value starts, which is past the key and its separator when there is a
  /// key. `indent` is the column the line the value started on begins at, which is what its
  /// closing bracket lines up with.
  private static void writeValue(JsonNode node, int indent, int column, StringBuilder out) {
    if (!node.isContainerNode() || node.isEmpty()) {
      out.append(oneLine(node));
      return;
    }

    if (node.isArray() && holdsOnlyScalars(node)) {
      var line = oneLine(node);
      if (column + line.length() <= MAX_WIDTH) {
        out.append(line);
        return;
      }
    }

    var inner = indent + INDENT;
    var padding = " ".repeat(inner);
    out.append(node.isObject() ? "{\n" : "[\n");

    if (node.isObject()) {
      var first = true;
      for (var field : node.properties()) {
        out.append(first ? "" : ",\n").append(padding).append(quoted(field.getKey()));
        out.append(KEY_SEPARATOR);
        writeValue(
            field.getValue(),
            inner,
            inner + quoted(field.getKey()).length() + KEY_SEPARATOR.length(),
            out);
        first = false;
      }
    } else {
      var first = true;
      for (var element : node) {
        out.append(first ? "" : ",\n").append(padding);
        writeValue(element, inner, inner, out);
        first = false;
      }
    }

    out.append('\n').append(" ".repeat(indent)).append(node.isObject() ? "}" : "]");
  }
}
