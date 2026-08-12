package dev.monogres.monobot.config.input;

import com.fasterxml.jackson.annotation.JsonProperty;
import dev.monogres.monobot.config.Metadata;
import dev.monogres.monobot.config.output.Sources;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.net.URL;
import java.util.Optional;

/// One entry's `monobot.json`, which is everything about that entry that monobot cannot work out
/// for itself.
///
/// `sources` and `metadata` are carried into `repo.json` as they stand. Between them they hold
/// every decision: which host serves the tarball, how a tag spells a version, which Postgres
/// majors the extension supports, which patches apply. What monobot derives is the digest of each
/// archive, and the placeholders the templates read that the version alone cannot fill.
///
/// `name` is the stem of the control file inside the archive, which is the extension's own name
/// and not the repository's: pgvector's is `vector`. It is optional, because the flavors have no
/// one control file to look for.
///
/// `url` is the git repository, and only tag discovery reads it, so it is required only alongside
/// a `versions.discover` block. postgis has both and they disagree on purpose: its tags are on
/// GitHub and its tarballs are not.
///
/// The two required fields are checked here because nothing else would. There is no nullability
/// module and no bean validation extension on the classpath, so an annotation saying so is a
/// comment, and a config missing `sources` reaches the materializer as a null with nothing in it
/// naming the file it came from.
@RegisterForReflection
public record MonobotConfig(
    @JsonProperty(value = "version") MonobotConfigVersion monobotConfigVersion,
    String name,
    @JsonProperty(value = "type") ComponentType componentType,
    @JsonProperty(value = "url") URL repoUrl,
    Sources sources,
    @JsonProperty(value = "versions") VersionsSpec versionsSpec,
    Metadata metadata,
    boolean disabled) {
  public MonobotConfig {
    // Enforce default values that are enums
    if (monobotConfigVersion == null) {
      monobotConfigVersion = MonobotConfigVersion.V1;
    }
    if (componentType == null) {
      componentType = ComponentType.EXTENSION;
    }
    if (versionsSpec == null) {
      versionsSpec = new VersionsSpec();
    }
    if (metadata == null) {
      metadata = new Metadata();
    }

    if (sources == null || sources.isEmpty()) {
      throw new IllegalArgumentException("monobot.json declares no sources");
    }
    if (versionsSpec.discovery().isPresent() && repoUrl == null) {
      throw new IllegalArgumentException(
          "monobot.json discovers versions from tags and declares no url to list them from");
    }
    if (versionsSpec.pin().isEmpty() && versionsSpec.discovery().isEmpty()) {
      throw new IllegalArgumentException(
          "monobot.json pins no version and discovers none, so it names nothing to catalogue");
    }
  }

  /// The stem of the control file to look for inside each archive, where there is one to look for.
  public Optional<String> controlStem() {
    return Optional.ofNullable(name).filter(stem -> !stem.isBlank());
  }

  /// What every log line about this entry is prefixed with. The control stem where there is one,
  /// and otherwise the repository the archives come from, so a flavor is still named.
  public String label() {
    return controlStem().orElseGet(() -> String.valueOf(repoUrl));
  }
}
