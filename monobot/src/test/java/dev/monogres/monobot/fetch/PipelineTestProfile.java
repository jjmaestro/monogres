package dev.monogres.monobot.fetch;

import io.quarkus.test.junit.QuarkusTestProfile;
import java.nio.file.Path;
import java.util.Map;

/// Supplies the three directories the application requires as configuration. They are derived
/// rather than fixed so the test does not depend on where it is run from, which differs between
/// the Maven and Bazel builds.
public class PipelineTestProfile implements QuarkusTestProfile {
  static final Path ROOT = Path.of(System.getProperty("java.io.tmpdir"), "monobot-pipeline-test");
  static final Path CONFIG_DIR = ROOT.resolve("config");
  static final Path WORKDIR = ROOT.resolve("work");
  static final Path MONOGRES_REPO = ROOT.resolve("monogres");

  @Override
  public Map<String, String> getConfigOverrides() {
    return Map.of(
        "configDir", CONFIG_DIR.toString(),
        "workdir", WORKDIR.toString(),
        "monogresRepo", MONOGRES_REPO.toString());
  }
}
