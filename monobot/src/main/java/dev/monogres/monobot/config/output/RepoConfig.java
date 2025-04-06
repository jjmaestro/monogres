package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.file.Path;
import java.util.SortedMap;
import java.util.TreeMap;

public class RepoConfig {
  private static final String FILENAME = "repo.json";

  private final Version version;
  private final SortedMap<String, VersionContext> versions;

  public RepoConfig(Version version, SortedMap<String, VersionContext> versions) {
    this.version = version;
    this.versions = versions;
  }

  public RepoConfig(SortedMap<String, VersionContext> versions) {
    this(Version.V1, versions);
  }

  public RepoConfig() {
    this(Version.V1, new TreeMap<>());
  }

  public Version getVersion() {
    return version;
  }

  public SortedMap<String, VersionContext> getVersions() {
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
