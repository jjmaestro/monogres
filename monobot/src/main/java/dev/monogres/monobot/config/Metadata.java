package dev.monogres.monobot.config;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.HashMap;
import java.util.Map;

public record Metadata(@JsonProperty("compatible_with") Map<String, String> compatibleWith) {
  public Metadata() {
    this(new HashMap<>());
  }
}
