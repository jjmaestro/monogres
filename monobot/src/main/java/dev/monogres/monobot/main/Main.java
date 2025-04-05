package dev.monogres.monobot.main;

import dev.monogres.monobot.scan.Scan;
import io.quarkus.runtime.Quarkus;
import io.quarkus.runtime.QuarkusApplication;
import io.quarkus.runtime.annotations.QuarkusMain;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;

@QuarkusMain
public class Main {
  public static void main(String... args) {
    Quarkus.run(MyApp.class, args);
  }

  public static class MyApp implements QuarkusApplication {
    @Inject Scan scan;

    @ConfigProperty(name = "pauseForDebugging")
    long pauseForDebugging;

    @Override
    public int run(String... args) throws Exception {
      // This is useful for debugging if you want to connect a debugger
      Thread.sleep(pauseForDebugging);

      scan.run();

      return 0;
    }
  }
}
