package dev.monogres.monobot.main;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import dev.monogres.monobot.scan.Scan;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.ThrowingSupplier;

/// The main thread waits on a latch a Vert.x thread counts down. Nothing else settles the
/// composite future, so a request that never answers leaves the process waiting for as long as it
/// is left running.
class MainRunTimeoutTest {
  private static final Duration RUN_TIMEOUT = Duration.ofMillis(250);
  private static final Duration GIVE_UP = Duration.ofSeconds(5);

  private static Main.MyApp app(Future<Void> scanResult, Duration runTimeout) throws Exception {
    var scan = mock(Scan.class);
    when(scan.run()).thenReturn(scanResult);

    var app = new Main.MyApp();
    app.scan = scan;
    app.runTimeout = runTimeout;

    return app;
  }

  /// Preemptively, because the regression this guards is an unbounded wait: asserting on elapsed
  /// time afterwards would mean never getting there. `GIVE_UP` only has to leave room for the
  /// timeout under test, so a failure costs seconds rather than the target's own limit.
  private static int runWithin(Main.MyApp app) {
    return assertTimeoutPreemptively(GIVE_UP, (ThrowingSupplier<Integer>) app::run);
  }

  @Test
  void givesUpWhenTheScanDoesNotSettleInTime() throws Exception {
    assertEquals(1, runWithin(app(Promise.<Void>promise().future(), RUN_TIMEOUT)));
  }

  @Test
  void reportsSuccessWhenTheScanSucceeds() throws Exception {
    assertEquals(0, runWithin(app(Future.succeededFuture(), RUN_TIMEOUT)));
  }

  @Test
  void reportsFailureWhenTheScanFails() throws Exception {
    assertEquals(1, runWithin(app(Future.failedFuture(new RuntimeException("boom")), RUN_TIMEOUT)));
  }
}
