package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.vertx.core.Future;
import io.vertx.core.Promise;
import java.util.ArrayList;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;

/// The permit bookkeeping on its own. No Vert.x here: a free permit is a succeeded future, so its
/// continuation runs inline on the calling thread, which is what a queued permit's continuation
/// does too once it is handed one.
class DownloadLimiterTest {
  private static final int PERMITS = 4;

  private static DownloadLimiter limiter(int maxConcurrentDownloads) {
    var limiter = new DownloadLimiter();
    limiter.maxConcurrentDownloads = maxConcurrentDownloads;

    return limiter;
  }

  /// The supplier really can throw before it returns anything: creating the download directory
  /// turns any I/O error into a RuntimeException, and opening the file throws on EACCES, ENOSPC or
  /// EMFILE. Vert.x turns the throw into an ordinary failed future, so the caller cannot tell that
  /// a permit went with it, and once they are all gone every later download parks on a promise
  /// nothing will complete.
  @Test
  void supplierThatThrowsGivesItsPermitBack() {
    var limiter = limiter(PERMITS);

    for (var attempt = 0; attempt < PERMITS; attempt++) {
      limiter.withPermit(
          () -> {
            throw new IllegalStateException("EMFILE");
          });
    }

    var started = new AtomicBoolean();
    limiter.withPermit(
        () -> {
          started.set(true);
          return Future.succeededFuture("digest");
        });

    assertTrue(started.get(), "every permit was spent by a supplier that returned no future");
  }

  @Test
  void failedDownloadGivesItsPermitBack() {
    var limiter = limiter(PERMITS);

    for (var attempt = 0; attempt < PERMITS; attempt++) {
      limiter.withPermit(
          () -> Future.failedFuture(new IllegalStateException("connection refused")));
    }

    var started = new AtomicBoolean();
    limiter.withPermit(
        () -> {
          started.set(true);
          return Future.succeededFuture("digest");
        });

    assertTrue(started.get(), "every permit was spent by a download that failed");
  }

  /// The bound itself, and that a queued download starts as soon as one ahead of it settles.
  @Test
  void noMoreThanTheCapRunAtOnce() {
    var limiter = limiter(PERMITS);
    var held = new ArrayList<Promise<String>>();
    var started = new ArrayList<Integer>();

    for (var download = 0; download < PERMITS * 2; download++) {
      var index = download;
      limiter.withPermit(
          () -> {
            started.add(index);
            var promise = Promise.<String>promise();
            held.add(promise);

            return promise.future();
          });
    }

    assertEquals(PERMITS, started.size(), "more downloads started than there are permits");

    held.get(0).complete("digest");

    assertEquals(PERMITS + 1, started.size(), "settling one download released no permit");
  }
}
