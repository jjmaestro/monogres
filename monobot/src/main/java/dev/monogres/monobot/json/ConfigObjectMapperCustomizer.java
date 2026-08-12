package dev.monogres.monobot.json;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import io.quarkus.jackson.ObjectMapperCustomizer;
import jakarta.inject.Singleton;

/// What the mapper decides about a catalog document, which is its content and not its layout.
/// [CatalogPrinter] writes the tree the mapper builds, so indentation is not configured here.
@Singleton
public class ConfigObjectMapperCustomizer implements ObjectMapperCustomizer {
  @Override
  public void customize(ObjectMapper objectMapper) {
    objectMapper
        .setDefaultPropertyInclusion(JsonInclude.Include.NON_NULL)

        // For Monogres Bazel's scripts repo.json is important that keys remain ordered
        .enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);
  }
}
