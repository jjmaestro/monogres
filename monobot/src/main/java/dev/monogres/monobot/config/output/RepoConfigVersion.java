package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonValue;

public enum RepoConfigVersion {
  V1(1);

  private final int versionNumber;

  RepoConfigVersion(int versionNumber) {
    this.versionNumber = versionNumber;
  }

  @JsonValue
  public int getVersionNumber() {
    return versionNumber;
  }
}
