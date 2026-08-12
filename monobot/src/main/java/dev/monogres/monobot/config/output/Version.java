package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonValue;
import dev.monogres.monobot.config.NaturalOrder;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.Optional;
import org.semver4j.Semver;
import org.semver4j.range.RangeListFactory;

/// One version of one entry, held as the string the catalog keys it on and never rewritten.
///
/// Rewriting is what a semantic version parser would do, and the key cannot afford it: `{version}`
/// is substituted into `strip_prefix` and `url` as it stands, so a key normalised to three
/// components names an archive that is not there. sslutils is `1.4` and unpacks to `sslutils-1.4`,
/// postgres is `16.11`, and openhalo is `1beta1`, which no parser reads at all.
///
/// Semantic versioning is therefore a view over the string rather than what it is. [#satisfies]
/// parses it, [#find] asks only whether it parses, and ordering is [NaturalOrder], which every key
/// has.
@RegisterForReflection
public final class Version implements Comparable<Version> {
  private final String version;

  public Version(String version) {
    if (version == null || version.isBlank()) {
      throw new IllegalArgumentException("a version is a string and not a blank one");
    }
    this.version = version;
  }

  /// `Optional.empty()` where the string names no version, which is the question asked of a
  /// discovered tag: a repository tags what is not a release, and the scan skips those. What comes
  /// back holds the string as it stands, so the `replace` rule spells the key and the parser only
  /// says whether it is one.
  public static Optional<Version> find(String version) {
    return version == null || version.isBlank()
        ? Optional.empty()
        : semverOf(version).map(parsed -> new Version(version));
  }

  /// A missing patch component is the one liberty taken, because two components is a version the
  /// catalog holds and semver does not. A leading `v` needs no handling here, the parser reads
  /// past it.
  ///
  /// Coercion would go further and is deliberately not used: it reads `REL1_2_3` as `1.0.0`, which
  /// would call a tag a version on the strength of a digit in it.
  private static Optional<Semver> semverOf(String version) {
    return Optional.ofNullable(Semver.parse(version))
        .or(() -> Optional.ofNullable(Semver.parse(version + ".0")));
  }

  public static boolean isRange(String range) {
    return !RangeListFactory.create(range, true).get().isEmpty();
  }

  @JsonValue
  public String version() {
    return version;
  }

  /// Whether this version falls in a node-semver range. Pre-releases take part, unlike in node,
  /// because a version such as `1.4.0-2` here is a packaging revision of a release rather than a
  /// candidate for one, and leaving them out would drop them from every range.
  ///
  /// A key no parser reads has no range that keeps it, and saying so is the only honest answer:
  /// reporting it as outside every range would drop it from a catalog that pins it.
  public boolean satisfies(String range) {
    return semverOf(version)
        .orElseThrow(
            () ->
                new IllegalArgumentException(
                    version + " is not a semantic version, so no range decides it"))
        .satisfies(range, /* includePreRelease= */ true);
  }

  @Override
  public int compareTo(Version version) {
    return NaturalOrder.compare(this.version, version.version);
  }

  @Override
  public boolean equals(Object object) {
    return object instanceof Version other && version.equals(other.version);
  }

  @Override
  public int hashCode() {
    return version.hashCode();
  }

  @Override
  public String toString() {
    return version;
  }
}
