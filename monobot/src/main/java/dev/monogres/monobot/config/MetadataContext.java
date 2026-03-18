package dev.monogres.monobot.config;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.Comparator;
import java.util.TreeMap;

public class MetadataContext extends TreeMap<String, JsonNode> {

  private static final long serialVersionUID = 1L;

  public MetadataContext() {
    super(Comparator.reverseOrder());
  }
}
