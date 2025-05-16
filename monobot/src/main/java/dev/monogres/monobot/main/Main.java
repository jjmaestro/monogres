package dev.monogres.monobot.main;

import dev.monogres.monobot.scan.Scan;
import io.quarkus.runtime.Quarkus;
import io.quarkus.runtime.QuarkusApplication;
import io.quarkus.runtime.annotations.QuarkusMain;
import jakarta.inject.Inject;

@QuarkusMain
public class Main {
  public static void main(String... args) {
    Quarkus.run(MyApp.class, args);
  }

  public static class MyApp implements QuarkusApplication {
    @Inject Scan scan;

    @Override
    public int run(String... args) throws Exception {
      scan.run();

      return 0;
    }
  }
}
