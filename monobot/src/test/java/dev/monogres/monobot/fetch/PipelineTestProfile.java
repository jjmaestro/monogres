package dev.monogres.monobot.fetch;

import io.quarkus.test.junit.QuarkusTestProfile;
import java.nio.file.Path;
import java.util.Map;

/// Supplies the two directories the application requires as configuration. Derived from
/// `java.io.tmpdir` rather than written down, so a test does not depend on where it is run from:
/// under Bazel that is a sandbox directory the test does not choose.
public class PipelineTestProfile implements QuarkusTestProfile {
  static final Path ROOT = Path.of(System.getProperty("java.io.tmpdir"), "monobot-pipeline-test");
  static final Path CATALOG_DIR = ROOT.resolve("catalog");
  static final Path CACHE_DIR = ROOT.resolve("cache");

  @Override
  public Map<String, String> getConfigOverrides() {
    return Map.of(
        "catalogDir", CATALOG_DIR.toString(),
        "cacheDir", CACHE_DIR.toString());
  }
}
