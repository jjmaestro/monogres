package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonGetter;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonSetter;
import org.eclipse.jgit.lib.ObjectId;

public class VersionContext {
  public static final int SHORT_COMMIT_LENGTH = 7;

  @JsonProperty(value = "tag")
  private String tag;

  @JsonIgnore private ObjectId objectId;

  @JsonProperty(value = "sha256")
  private String archiveSha256;

  public VersionContext(String tag, ObjectId objectId, String archiveSha256) {
    this.tag = tag;
    this.objectId = objectId;
    this.archiveSha256 = archiveSha256;
  }

  @JsonGetter(value = "commit")
  public String getCommit() {
    return objectId.name();
  }

  @JsonGetter(value = "short_commit")
  public String getShortCommit() {
    return objectId.abbreviate(SHORT_COMMIT_LENGTH).name();
  }

  @JsonSetter(value = "commit")
  public void fromObjectId(String objectId) {
    this.objectId = ObjectId.fromString(objectId);
  }
}
