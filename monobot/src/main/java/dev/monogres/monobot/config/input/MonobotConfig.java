package dev.monogres.monobot.config.input;

import com.fasterxml.jackson.annotation.JsonProperty;
import dev.monogres.monobot.config.Metadata;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.net.URL;

/// One extension's `monobot.json`.
///
/// `name` and `url` are required and are checked here, because nothing else would check them.
/// There is no nullability module and no bean validation extension on the classpath, so an
/// annotation saying so is a comment: a config missing `url` would deserialize to a null and reach
/// the forge lookup, where it is a NullPointerException with nothing in it naming the file it came
/// from.
@RegisterForReflection
public record MonobotConfig(
    @JsonProperty(value = "version") MonobotConfigVersion monobotConfigVersion,
    String name,
    @JsonProperty(value = "type") ComponentType componentType,
    @JsonProperty(value = "url") URL repoUrl,
    @JsonProperty(value = "versions") VersionSpec versionSpec,
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
    if (versionSpec == null) {
      versionSpec = new VersionSpec();
    }

    requireDeclared("name", name);
    requireDeclared("url", repoUrl);
  }

  private static void requireDeclared(String key, Object value) {
    if (value == null || (value instanceof String declared && declared.isBlank())) {
      throw new IllegalArgumentException("monobot.json declares no " + key);
    }
  }
}
