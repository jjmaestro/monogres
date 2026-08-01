package dev.monogres.monobot.config;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.fasterxml.jackson.databind.node.TextNode;
import dev.monogres.monobot.config.output.Version;
import dev.monogres.monobot.config.output.Versions;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

/// `metadata.<category>` and `versions` are keyed the same way in the same document, so they have
/// to sort the same way. Plain string order does not: it puts `1.10.0` last and `debian9` first.
class MetadataContextTest {
  private static List<String> keysOf(String... keys) {
    var metadataContext = new MetadataContext();
    for (var key : keys) {
      metadataContext.put(key, TextNode.valueOf(key));
    }

    return List.copyOf(metadataContext.keySet());
  }

  private static List<String> versionKeysOf(String... versions) {
    var out = new Versions();
    for (var version : versions) {
      out.put(new Version(version), null);
    }

    return out.keySet().stream().map(Version::version).toList();
  }

  @Test
  void twoDigitComponentsSortAboveSingleDigitOnes() {
    assertEquals(List.of("1.10.0", "1.9.0", "1.2.0"), keysOf("1.9.0", "1.10.0", "1.2.0"));
  }

  @Test
  void singleDigitVersionsKeepTheOrderTheyAlreadyHad() {
    assertEquals(List.of("0.3.0", "0.2.0", "0.1.0"), keysOf("0.1.0", "0.3.0", "0.2.0"));
  }

  /// config/extensions/sslutils/monobot.json keys this map by distribution rather than by version,
  /// so the numbers inside a key have to count there too.
  @Test
  void numbersInsideNonVersionKeysCountAsNumbers() {
    assertEquals(List.of("debian13", "debian9"), keysOf("debian9", "debian13"));
  }

  @Test
  void keysWithNoDigitsFallBackToStringOrder() {
    assertEquals(List.of("zulu", "alpha"), keysOf("alpha", "zulu"));
  }

  @Test
  void keysThatDifferOnlyInLeadingZeroesStayDistinct() {
    assertEquals(2, keysOf("1.0", "1.00").size());
  }

  @Test
  void versionKeysComeOutInTheSameOrderAsTheVersionsBlock() {
    var versions = new String[] {"1.9.0", "1.10.0", "1.2.0", "2.0.0", "10.0.0"};
    var expected = new ArrayList<>(versionKeysOf(versions));

    assertEquals(expected, keysOf(versions));
  }
}
