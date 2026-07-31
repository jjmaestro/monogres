package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonValue;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.Objects;

@RegisterForReflection
public record Version(String tag) implements Comparable<Version> {
  public static String normalize(String tag) {
    return tag
        // Remove "v" prefix when followed by number, as what follows is the version "string"
        .replaceFirst("^v([0-9])", "$1");
  }

  @JsonValue
  public String normalize() {
    return normalize(tag);
  }

  // We want versions to be ordered in reverse order
  // TODO: implement semantic versioning ordering instead of alphabetical
  private int reverseCompareTo(Version o) {
    if (o == null) {
      return 1;
    }

    return normalize().compareTo(normalize(o.tag()));
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

    return Objects.equals(normalize(), normalize(version.tag));
  }

  @Override
  public int hashCode() {
    return Objects.hashCode(normalize());
  }
}
