package dev.monogres.monobot.it;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.quarkus.test.junit.main.QuarkusMainIntegrationTest;
import io.quarkus.test.junit.main.QuarkusMainLauncher;
import java.io.IOException;
import java.nio.file.Files;
import org.junit.jupiter.api.Test;

/**
 * Runs the packaged application the way Quarkus does it, as a counterpart to the shell test in
 * //tests. Both answer the same question: an image keeps only the members it can prove are
 * reachable, and every type monobot exchanges as JSON is reached only through Jackson, so a build
 * that drops their reflection leaves an application that starts and then cannot read a thing.
 *
 * <p>The fixture is written here rather than taken from a file, because the rule behind this test
 * carries no data attribute: everything it needs has to arrive over the classpath or be made at run
 * time, and four lines of JSON are clearer made than shipped.
 */
@QuarkusMainIntegrationTest
class MonobotMainIT {

  private static final String CONFIG =
      """
      {
        "name": "unreachable",
        "url": "https://github.com/ongres/monobot-no-such-repository"
      }
      """;

  @Test
  void readsItsConfigBeforeItReachesTheNetwork(QuarkusMainLauncher launcher) throws IOException {
    var configDir = Files.createTempDirectory("monobot-it-config");
    var extension = Files.createDirectories(configDir.resolve("extensions/unreachable"));
    Files.writeString(extension.resolve("monobot.json"), CONFIG);

    var result =
        launcher.launch(
            "-DconfigDir=" + configDir,
            "-DcacheDir=" + Files.createTempDirectory("monobot-it-cache"),
            "-DmonogresRepo=" + Files.createTempDirectory("monobot-it-repo"));

    var output = result.getOutput() + result.getErrorOutput();

    assertFalse(
        output.contains("InvalidDefinitionException") || output.contains("cannot deserialize"),
        "the packaged application could not construct its JSON types:\n" + output);

    // Only a config that was deserialized into an object, and whose fields were
    // read back out, can put this in the output.
    assertTrue(
        output.contains("monobot-no-such-repository"),
        "the run never read the URL out of its config:\n" + output);
  }
}
