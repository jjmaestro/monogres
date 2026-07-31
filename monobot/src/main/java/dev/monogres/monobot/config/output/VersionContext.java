package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonGetter;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import com.fasterxml.jackson.annotation.JsonSetter;
import dev.monogres.monobot.git.ObjectIdUtils;
import io.quarkus.runtime.annotations.RegisterForReflection;
import org.eclipse.jgit.lib.ObjectId;

/// `tag`, `sha256` and `strip_prefix` are serialized from fields while `commit` and
/// `short_commit` come from getters, and Jackson derives the latter from
/// `Class.getDeclaredMethods()`, whose order the JVM explicitly does not specify. Without a
/// declared order the two commit keys swap between runs, so repo.json is not reproducible.
@JsonPropertyOrder({"tag", "sha256", "strip_prefix", "commit", "short_commit"})
@RegisterForReflection
public class VersionContext {
  @JsonProperty(value = "tag")
  private String tag;

  @JsonIgnore private ObjectId objectId;

  @JsonProperty(value = "sha256")
  private String archiveSha256;

  @JsonProperty(value = "strip_prefix")
  private String stripPrefix;

  private VersionContext() {}

  public VersionContext(String tag, ObjectId objectId, String archiveSha256, String stripPrefix) {
    this.tag = tag;
    this.objectId = objectId;
    this.archiveSha256 = archiveSha256;
    this.stripPrefix = stripPrefix;
  }

  @JsonGetter(value = "commit")
  public String getCommit() {
    return objectId.name();
  }

  @JsonGetter(value = "short_commit")
  public String getShortCommit() {
    return ObjectIdUtils.shortCommit(objectId);
  }

  @JsonSetter(value = "commit")
  public void fromObjectId(String objectId) {
    this.objectId = ObjectId.fromString(objectId);
  }

  @JsonSetter(value = "strip_prefix")
  public void setStripPrefix(String stripPrefix) {
    this.stripPrefix = stripPrefix;
  }
}
