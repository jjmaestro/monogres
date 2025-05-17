package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonProperty;
import dev.monogres.monobot.config.Metadata;

public class RepoConfig {
  @JsonProperty("version")
  private final RepoConfigVersion repoConfigVersion;

  private final Sources sources;
  private final Versions versions;
  private final Metadata metadata;

  public RepoConfig(
      RepoConfigVersion repoConfigVersion, Sources sources, Versions versions, Metadata metadata) {
    this.repoConfigVersion = repoConfigVersion;
    this.sources = sources;
    this.versions = versions;
    this.metadata = metadata;
  }

  public RepoConfig(Sources sources, Versions versions, Metadata metadata) {
    this(RepoConfigVersion.V1, sources, versions, metadata);
  }

  public RepoConfig() {
    this(RepoConfigVersion.V1, new Sources(), new Versions(), new Metadata());
  }

  public RepoConfigVersion getVersion() {
    return repoConfigVersion;
  }

  public Versions getVersions() {
    return versions;
  }

  public Sources getSources() {
    return sources;
  }
}
