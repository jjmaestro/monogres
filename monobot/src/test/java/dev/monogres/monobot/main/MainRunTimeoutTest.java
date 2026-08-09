package dev.monogres.monobot.main;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import dev.monogres.monobot.report.RunSummary;
import dev.monogres.monobot.scan.Scan;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.ThrowingSupplier;

/// The main thread waits on a latch a Vert.x thread counts down, and what it reports afterwards.
/// Nothing else settles the composite future, so a request that never answers leaves the process
/// waiting for as long as it is left running.
///
/// The exit code tells three outcomes apart: everything the scan found completed, some completed
/// and some failed, or none completed.
class MainRunTimeoutTest {
  private static final Duration RUN_TIMEOUT = Duration.ofMillis(250);
  private static final Duration GIVE_UP = Duration.ofSeconds(5);

  private static Main.MyApp app(Future<Void> scanResult, Duration runTimeout) throws Exception {
    var scan = mock(Scan.class);
    when(scan.run()).thenReturn(scanResult);

    var app = new Main.MyApp();
    app.scan = scan;
    app.summary = new RunSummary();
    app.runTimeout = runTimeout;

    return app;
  }

  /// Preemptively, because the regression this guards is an unbounded wait: asserting on elapsed
  /// time afterwards would mean never getting there. `GIVE_UP` only has to leave room for the
  /// timeout under test, so a failure costs seconds rather than the target's own limit.
  private static int runWithin(Main.MyApp app) {
    return assertTimeoutPreemptively(GIVE_UP, (ThrowingSupplier<Integer>) app::run);
  }

  /// A run that did not finish catalogued nothing it can answer for, so it reports the same
  /// outcome as a run in which nothing succeeded.
  @Test
  void givesUpWhenTheScanDoesNotSettleInTime() throws Exception {
    assertEquals(
        RunSummary.NOTHING_SUCCEEDED,
        runWithin(app(Promise.<Void>promise().future(), RUN_TIMEOUT)));
  }

  @Test
  void reportsSuccessWhenTheScanSucceeds() throws Exception {
    assertEquals(
        RunSummary.EVERYTHING_SUCCEEDED, runWithin(app(Future.succeededFuture(), RUN_TIMEOUT)));
  }

  /// A composite that failed says something failed even where the summary counted nothing against
  /// it, which is what a wholesale-mocked scan produces.
  @Test
  void reportsFailureWhenTheScanFails() throws Exception {
    assertEquals(
        RunSummary.SOME_EXTENSIONS_FAILED,
        runWithin(app(Future.failedFuture(new RuntimeException("boom")), RUN_TIMEOUT)));
  }

  @Test
  void reportsThatNothingSucceededWhenEveryExtensionFailed() throws Exception {
    var app = app(Future.succeededFuture(), RUN_TIMEOUT);
    app.summary.extensionScanned();
    app.summary.extensionFailed();

    assertEquals(RunSummary.NOTHING_SUCCEEDED, runWithin(app));
  }

  @Test
  void reportsThatSomeFailedWhenOthersSucceeded() throws Exception {
    var app = app(Future.succeededFuture(), RUN_TIMEOUT);
    app.summary.extensionScanned();
    app.summary.extensionScanned();
    app.summary.extensionFailed();

    assertEquals(RunSummary.SOME_EXTENSIONS_FAILED, runWithin(app));
  }
}
