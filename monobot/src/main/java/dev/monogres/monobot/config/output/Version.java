package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonValue;
import java.util.Objects;

public record Version(String tag) implements Comparable<Version> {
  public static String normalizeFromTag(String tag) {
    return tag
        // Remove "v" prefix when followed by number, as what follows is the version "string"
        .replaceFirst("^v([0-9])", "$1");
  }

  @JsonValue
  public String toString() {
    return normalizeFromTag(tag);
  }

  // We want versions to be ordered in reverse order
  // TODO: implement semantic versioning ordering instead of alphabetical
  private int reverseCompareTo(Version o) {
    if (o == null) {
      return 1;
    }

    return normalizeFromTag(tag).compareTo(o.tag());
  }

  @Override
  public int compareTo(Version o) {
    return -reverseCompareTo(o);
  }

  @Override
  public boolean equals(Object o) {
    if (o == null || getClass() != o.getClass()) {
      return false;
    }

    var version = (Version) o;

    return Objects.equals(tag, version.tag);
  }

  @Override
  public int hashCode() {
    return Objects.hashCode(tag);
  }
}
