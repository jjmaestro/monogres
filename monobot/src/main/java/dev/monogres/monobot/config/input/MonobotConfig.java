package dev.monogres.monobot.config.input;

import com.fasterxml.jackson.annotation.JsonProperty;
import dev.monogres.monobot.config.Metadata;
import io.quarkus.runtime.annotations.RegisterForReflection;
import jakarta.annotation.Nonnull;
import java.net.URL;

@RegisterForReflection
public record MonobotConfig(
    @JsonProperty(value = "version") MonobotConfigVersion monobotConfigVersion,
    @Nonnull String name,
    @JsonProperty(value = "type") ComponentType componentType,
    @Nonnull @JsonProperty(value = "url") URL repoUrl,
    Metadata metadata) {
  public MonobotConfig {
    // Enforce default values that are enums
    if (monobotConfigVersion == null) {
      monobotConfigVersion = MonobotConfigVersion.V1;
    }
    if (componentType == null) {
      componentType = ComponentType.EXTENSION;
    }
  }
}
