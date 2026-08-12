package dev.monogres.monobot.config.input;

import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.Optional;

/// The `versions` block of a `monobot.json`: which versions the catalog holds, and where they come
/// from.
///
/// `pin` names them outright and is how the catalog is written today. `discover` reads them off
/// the repository's tags instead, and an entry carrying it is one that follows its upstream. The
/// two compose: a pinned version is catalogued whether or not the tags still name it, which is
/// what keeps a pin from being undone by a repository that retags.
@RegisterForReflection
public record VersionsSpec(PinnedVersions pin, DiscoverySpec discover) {
  public VersionsSpec() {
    this(null, null);
  }

  public VersionsSpec {
    if (pin == null) {
      pin = new PinnedVersions();
    }
  }

  public Optional<DiscoverySpec> discovery() {
    return Optional.ofNullable(discover);
  }
}
