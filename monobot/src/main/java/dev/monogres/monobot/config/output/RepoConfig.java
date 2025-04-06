package dev.monogres.monobot.config.output;

import java.util.HashMap;
import java.util.Map;

public record RepoConfig(Version version, Map<String, VersionContext> versions) {
  public RepoConfig(Map<String, VersionContext> versions) {
    this(Version.V1, versions);
  }

  public RepoConfig() {
    this(Version.V1, new HashMap<>());
  }
}
