package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonGetter;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonSetter;
import dev.monogres.monobot.git.ObjectIdUtils;
import org.eclipse.jgit.lib.ObjectId;

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
