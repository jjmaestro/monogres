package dev.monogres.monobot.main;

import dev.monogres.monobot.report.RunSummary;
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

    @Inject RunSummary summary;

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
        return RunSummary.NOTHING_SUCCEEDED;
      }

      // On the way out of every run, whatever the outcome. Every per-extension failure is
      // survivable by design, which leaves counting log lines as the only other way to tell a run
      // with nothing to do from a run where every extension was refused.
      LOG.info(summary.line());

      // A composite that failed says something failed even where no extension was counted against
      // it, so it can raise the outcome but never lower it.
      return scanFuture.failed()
          ? Math.max(RunSummary.SOME_EXTENSIONS_FAILED, summary.exitCode())
          : summary.exitCode();
    }
  }
}
