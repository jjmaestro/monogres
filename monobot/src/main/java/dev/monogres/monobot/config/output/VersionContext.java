package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonAnyGetter;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import dev.monogres.monobot.git.GitTag;
import java.util.HashMap;
import java.util.Map;

public record VersionContext(
    @JsonIgnore GitTag gitTag, @JsonProperty(value = "sha256") String archiveSha256) {
  private static final String JSON_PROPERTY_COMMIT = "commit";
  private static final String JSON_PROPERTY_TAG = "tag";

  @JsonAnyGetter
  public Map<String, String> gitTagGetter() {
    var map = new HashMap<String, String>();
    map.put(JSON_PROPERTY_COMMIT, gitTag.commit().name());
    map.put(JSON_PROPERTY_TAG, gitTag.name());

    return map;
  }
}
