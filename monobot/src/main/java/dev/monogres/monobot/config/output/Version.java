package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonValue;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.Optional;
import org.semver4j.Semver;
import org.semver4j.range.RangeListFactory;

/// One version of one extension, ordered by semantic version precedence rather than by the text it
/// was read from, so `1.10.0` comes after `1.9.0`.
///
/// [Versions] keys on this, so a `repo.json` read back from disk rebuilds the key from the json
/// property name through [#Version(String)] and writes it back through [#version()].
@RegisterForReflection
public final class Version implements Comparable<Version> {
  private final Semver semver;

  private Version(Semver semver) {
    this.semver = semver;
  }

  public Version(String version) {
    this(
        semverOf(version)
            .orElseThrow(() -> new IllegalArgumentException(version + " is not a version")));
  }

  /// `Optional.empty()` where the constructor throws: a repository can tag what is not a version,
  /// and the scan skips those.
  public static Optional<Version> find(String version) {
    return semverOf(version).map(Version::new);
  }

  /// A missing patch component is the one liberty taken, because two components is a version the
  /// catalog consumer accepts and semver does not. A leading `v` needs no handling here, the parser
  /// reads past it.
  ///
  /// Coercion would go further and is deliberately not used: it reads `REL1_2_3` as `1.0.0`, which
  /// catalogues a version the tag never named.
  private static Optional<Semver> semverOf(String version) {
    return Optional.ofNullable(Semver.parse(version))
        .or(() -> Optional.ofNullable(Semver.parse(version + ".0")));
  }

  public static boolean isRange(String range) {
    return !RangeListFactory.create(range, true).get().isEmpty();
  }

  @JsonValue
  public String version() {
    return semver.getVersion();
  }

  /// Whether this version falls in a node-semver range. Pre-releases take part, unlike in node,
  /// because a version such as `1.4.0-2` here is a packaging revision of a release rather than a
  /// candidate for one, and leaving them out would drop them from every range.
  public boolean satisfies(String range) {
    return semver.satisfies(range, /* includePreRelease= */ true);
  }

  @Override
  public int compareTo(Version version) {
    return semver.compareTo(version.semver);
  }

  @Override
  public boolean equals(Object object) {
    return object instanceof Version version && semver.equals(version.semver);
  }

  @Override
  public int hashCode() {
    return semver.hashCode();
  }

  @Override
  public String toString() {
    return version();
  }
}
