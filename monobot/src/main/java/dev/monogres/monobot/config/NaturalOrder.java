package dev.monogres.monobot.config;

import java.util.Comparator;

/// Compares two strings the way a version reads: a run of digits compares as the number it spells,
/// so `1.10.0` lands above `1.9.0` and `debian13` above `debian9`, where comparing them as text
/// disagrees as soon as a component reaches two digits.
///
/// One rule for every key, rather than semantic version precedence where the key parses and text
/// where it does not. That would not be a total order, and both the catalogs it sorts hold keys
/// nothing parses: `1beta1` is a version and `debian13` is not a version at all.
public class NaturalOrder {
  public static final Comparator<String> ASCENDING = NaturalOrder::compare;

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

  public static int compare(String left, String right) {
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
