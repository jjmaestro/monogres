package dev.monogres.monobot.config;

import com.fasterxml.jackson.databind.JsonNode;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.Comparator;
import java.util.TreeMap;

@RegisterForReflection
public class MetadataContext extends TreeMap<String, JsonNode> {

  private static final long serialVersionUID = 1L;

  public MetadataContext() {
    super(Comparator.reverseOrder());
  }
}
