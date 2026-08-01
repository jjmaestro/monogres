package dev.monogres.monobot.config;

import com.fasterxml.jackson.databind.JsonNode;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.Comparator;
import java.util.TreeMap;

/// Newest first, the way `versions` is ordered in the same document, since both are keyed by
/// version. Comparing the keys as strings would disagree as soon as a component reaches two
/// digits, so a run of digits compares as the number it spells: `1.10.0` above `1.9.0`.
///
/// The keys are not always versions. `config/extensions/sslutils/monobot.json` keys this map by
/// distribution, where the same rule is what puts `debian13` above `debian9`.
@RegisterForReflection
public class MetadataContext extends TreeMap<String, JsonNode> {

  private static final long serialVersionUID = 1L;

  private static final Comparator<String> NATURAL = MetadataContext::compareNatural;
  private static final Comparator<String> NEWEST_FIRST = NATURAL.reversed();

  public MetadataContext() {
    super(NEWEST_FIRST);
  }

  private static int digitRunEnd(String value, int from) {
    var end = from;
    while (end < value.length() && Character.isDigit(value.charAt(end))) {
      end++;
    }

    return end;
  }

  /// Length first, because a longer run of digits is the larger number once leading zeroes are
  /// gone, and same-length runs compare digit by digit.
  private static int compareDigitRuns(String left, String right) {
    var leftDigits = left.replaceFirst("^0+(?=.)", "");
    var rightDigits = right.replaceFirst("^0+(?=.)", "");

    return leftDigits.length() != rightDigits.length()
        ? Integer.compare(leftDigits.length(), rightDigits.length())
        : leftDigits.compareTo(rightDigits);
  }

  private static int compareNatural(String left, String right) {
    var leftAt = 0;
    var rightAt = 0;

    while (leftAt < left.length() && rightAt < right.length()) {
      if (Character.isDigit(left.charAt(leftAt)) && Character.isDigit(right.charAt(rightAt))) {
        var leftEnd = digitRunEnd(left, leftAt);
        var rightEnd = digitRunEnd(right, rightAt);
        var byNumber =
            compareDigitRuns(left.substring(leftAt, leftEnd), right.substring(rightAt, rightEnd));
        if (byNumber != 0) {
          return byNumber;
        }
        leftAt = leftEnd;
        rightAt = rightEnd;
      } else {
        if (left.charAt(leftAt) != right.charAt(rightAt)) {
          return Character.compare(left.charAt(leftAt), right.charAt(rightAt));
        }
        leftAt++;
        rightAt++;
      }
    }

    var byRemainder = Integer.compare(left.length() - leftAt, right.length() - rightAt);

    // Two different keys that compare alike run by run, `1.0` and `1.00` for instance, would
    // collapse into a single entry in a sorted map, so the string itself settles the tie.
    return byRemainder != 0 ? byRemainder : left.compareTo(right);
  }
}
