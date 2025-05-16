package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonValue;

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

  @Override
  public int compareTo(Version o) {
    if (o == null) {
      return 1;
    }

    return tag.compareTo(o.tag());
  }
}
