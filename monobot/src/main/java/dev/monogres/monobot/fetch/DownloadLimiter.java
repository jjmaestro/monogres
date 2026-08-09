package dev.monogres.monobot.fetch;

import io.vertx.core.Future;
import io.vertx.core.Promise;
import jakarta.enterprise.context.ApplicationScoped;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.function.Supplier;
import org.eclipse.microprofile.config.inject.ConfigProperty;

/// Caps how many downloads are in flight at once. Application scoped on purpose: the cap is over
/// the whole run rather than over one extension, since a scan starts every extension at the same
/// time and each of them every one of its versions, so a per-extension cap would multiply by
/// however many configs the tree happens to hold.
///
/// Permits are handed over rather than waited for. The callers are on an event loop, so blocking
/// one to wait for a permit would stall the very responses that release them.
@ApplicationScoped
public class DownloadLimiter {
  @ConfigProperty(name = "maxConcurrentDownloads")
  int maxConcurrentDownloads;

  private final Deque<Promise<Void>> waiting = new ArrayDeque<>();

  private int inFlight;

  private synchronized Future<Void> acquire() {
    if (inFlight < maxConcurrentDownloads) {
      inFlight++;
      return Future.succeededFuture();
    }
    var promise = Promise.<Void>promise();
    waiting.add(promise);

    return promise.future();
  }

  /// Completing a promise runs its continuation, which starts the next download and can release
  /// again, so the queue is left before that happens rather than during it.
  private void release() {
    Promise<Void> next;
    synchronized (this) {
      next = waiting.poll();
      if (next == null) {
        inFlight--;
        return;
      }
    }
    next.complete();
  }

  /// The release hangs off the composed future rather than off the one the supplier returns,
  /// because that is the future that exists whatever the supplier does. `compose` turns a
  /// synchronous throw out of the supplier into a failed future, and a supplier that throws
  /// returns nothing to attach anything to: creating the download directory turns any I/O error
  /// into a RuntimeException, and opening the file throws on EACCES, ENOSPC or EMFILE.
  public <T> Future<T> withPermit(Supplier<Future<T>> download) {
    return acquire().compose(permit -> download.get()).onComplete(finished -> release());
  }
}
