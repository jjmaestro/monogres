package dev.monogres.monobot.config;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.TreeMap;
import org.junit.jupiter.api.Test;

/// The one rule that orders every key monobot sorts, whether or not anything parses it. Plain
/// string order does not do: it puts `1.10.0` below `1.9.0` and `debian13` below `debian9`.
class NaturalOrderTest {
  private static List<String> sorted(String... keys) {
    var sorted = new TreeMap<String, String>(NaturalOrder.ASCENDING);
    for (var key : keys) {
      sorted.put(key, key);
    }

    return List.copyOf(sorted.keySet());
  }

  @Test
  void runsOfDigitsCompareAsTheNumbersTheySpell() {
    assertEquals(List.of("1.2.0", "1.9.0", "1.10.0"), sorted("1.9.0", "1.10.0", "1.2.0"));
    assertEquals(List.of("16.9", "16.10", "16.11"), sorted("16.11", "16.9", "16.10"));
  }

  /// A catalog entry keys `deps` by distribution rather than by version, so the numbers inside a
  /// key have to count there too.
  @Test
  void numbersInsideKeysThatAreNotVersionsCountAsNumbers() {
    assertEquals(List.of("debian9", "debian13"), sorted("debian13", "debian9"));
  }

  @Test
  void keysWithNoDigitsFallBackToStringOrder() {
    assertEquals(List.of("alpha", "zulu"), sorted("zulu", "alpha"));
  }

  @Test
  void keysThatDifferOnlyInLeadingZeroesStayDistinct() {
    assertEquals(2, sorted("1.0", "1.00").size());
  }

  /// `1beta1` is a key `build/catalog` holds and nothing parses. It has to order against a
  /// well-formed version rather than throw, which is the whole reason this rule is the only one.
  @Test
  void keysNoVersionParserReadsStillOrder() {
    assertEquals(List.of("1beta1", "2.0.0"), sorted("2.0.0", "1beta1"));
    assertTrue(NaturalOrder.compare("1beta1", "1beta2") < 0);
  }

  @Test
  void theOrderIsTotalAndSelfConsistent() {
    var keys = List.of("1.0", "1.00", "1.9.0", "1.10.0", "1beta1", "debian9", "16.11", "2.0.0");

    for (var left : keys) {
      for (var right : keys) {
        var forwards = NaturalOrder.compare(left, right);
        var backwards = NaturalOrder.compare(right, left);

        assertEquals(
            Integer.signum(forwards),
            -Integer.signum(backwards),
            left + " against " + right + " does not reverse");
      }
    }
  }
}
