package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import dev.monogres.monobot.config.Metadata;
import io.quarkus.runtime.annotations.RegisterForReflection;

/// One `repo.json`: the index the monogres Bazel build downloads an entry's archives from.
///
/// `version`, `sources`, `versions`, `metadata`, in that order, which is the order the catalog is
/// written in. Jackson derives getter order from `Class.getDeclaredMethods()`, whose order the JVM
/// explicitly does not specify, so declaring it is what keeps two runs over the same inputs
/// producing the same bytes.
@JsonPropertyOrder({"version", "sources", "versions", "metadata"})
@RegisterForReflection
public class RepoConfig {
  @JsonProperty("version")
  private final RepoConfigVersion repoConfigVersion;

  private final Sources sources;
  private final Versions versions;

  @JsonInclude(JsonInclude.Include.NON_NULL)
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

  /// No Java caller, and load-bearing all the same: without it Jackson cannot see the field, and
  /// reading a stored `repo.json` back throws.
  public Sources getSources() {
    return sources;
  }

  public Metadata getMetadata() {
    return metadata;
  }
}
