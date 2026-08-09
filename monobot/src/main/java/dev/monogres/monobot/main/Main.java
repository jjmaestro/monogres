package dev.monogres.monobot.main;

import dev.monogres.monobot.scan.Scan;
import io.quarkus.runtime.Quarkus;
import io.quarkus.runtime.QuarkusApplication;
import io.quarkus.runtime.annotations.QuarkusMain;
import jakarta.inject.Inject;
import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@QuarkusMain
public class Main {
  private static final Logger LOG = Logger.getLogger(Main.class);

  public static void main(String... args) {
    Quarkus.run(MyApp.class, args);
  }

  public static class MyApp implements QuarkusApplication {
    @Inject Scan scan;

    @ConfigProperty(name = "runTimeout")
    Duration runTimeout;

    @Override
    public int run(String... args) throws Exception {
      var latch = new CountDownLatch(1);

      var scanFuture =
          scan.run()
              .onSuccess(v -> latch.countDown())
              .onFailure(
                  err -> {
                    LOG.error("Failed to complete scan", err);
                    latch.countDown();
                  });

      // The composite future is the only thing that counts this down, and it settles only when
      // every extension has. Without a bound the process outlives any request that never answers.
      if (!latch.await(runTimeout.toMillis(), TimeUnit.MILLISECONDS)) {
        LOG.errorv("Gave up waiting for the scan after {0}", runTimeout);
        return 1;
      }

      return scanFuture.failed() ? 1 : 0;
    }
  }
}
