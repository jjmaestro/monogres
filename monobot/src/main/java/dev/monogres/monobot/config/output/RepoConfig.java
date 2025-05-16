package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.Metadata;
import java.io.IOException;
import java.nio.file.Path;
import java.util.SortedMap;

public class RepoConfig {
  private static final String FILENAME = "repo.json";

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

  public SortedMap<Version, VersionContext> getVersions() {
    return versions;
  }

  public void writeRepoConfig(Path configDir, ObjectMapper objectMapper) {
    try {
      // TODO: we want the keys to be serialized in the order they are given
      // .enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS) should help, but it isn't
      objectMapper
          .writerWithDefaultPrettyPrinter()
          .writeValue(configDir.resolve(FILENAME).toFile(), this);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }
}
