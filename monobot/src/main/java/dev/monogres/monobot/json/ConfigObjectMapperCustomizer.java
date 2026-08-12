package dev.monogres.monobot.json;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.quarkus.jackson.ObjectMapperCustomizer;
import jakarta.inject.Singleton;

/// What the mapper decides about a catalog document, which is its content and not its layout.
/// [dev.monogres.monobot.json.CatalogPrinter] writes the tree the mapper builds, so indentation is
/// not configured here.
///
/// Map entries are not sorted. Every map the document is built from states its own order and the
/// order is part of what it says: a `sources` property may only read what is declared above it,
/// `versions` reads the way the entry lists them, and `metadata` comes back the way it went in.
/// Sorting any of them would rewrite the document.
@Singleton
public class ConfigObjectMapperCustomizer implements ObjectMapperCustomizer {
  @Override
  public void customize(ObjectMapper objectMapper) {
    objectMapper.setDefaultPropertyInclusion(JsonInclude.Include.NON_NULL);
  }
}
