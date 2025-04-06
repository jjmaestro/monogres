package dev.monogres.monobot.config.output;

import com.fasterxml.jackson.annotation.JsonValue;

public enum Version {
  V1(1);

  private final int versionNumber;

  Version(int versionNumber) {
    this.versionNumber = versionNumber;
  }

  @JsonValue
  public int getVersionNumber() {
    return versionNumber;
  }
}
