package dev.monogres.monobot.config.input;

import com.fasterxml.jackson.annotation.JsonValue;

public enum MonobotConfigVersion {
  V1(1);

  private final int versionNumber;

  MonobotConfigVersion(int versionNumber) {
    this.versionNumber = versionNumber;
  }

  @JsonValue
  public int getVersionNumber() {
    return versionNumber;
  }
}
