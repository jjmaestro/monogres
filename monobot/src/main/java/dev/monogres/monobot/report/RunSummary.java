package dev.monogres.monobot.report;

import jakarta.enterprise.context.ApplicationScoped;
import java.util.EnumMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Collectors;

/// What one run did, and the exit code that follows from it.
///
/// Every per-extension failure is deliberately survivable, which leaves the log as the only place
/// they are recorded and every one of them as a line among the others. Counting them is what lets
/// the process say, in one line and in its exit code, the difference between a run with nothing to
/// do and a run in which every extension was rate limited.
@ApplicationScoped
public class RunSummary {
  /// Every extension the scan found completed.
  public static final int EVERYTHING_SUCCEEDED = 0;

  /// Some completed and some failed.
  public static final int SOME_EXTENSIONS_FAILED = 1;

  /// None completed: either every extension failed, or the run did not finish in time.
  public static final int NOTHING_SUCCEEDED = 2;

  /// Why a tag the listing returned is not a catalog entry this run. These are the ordinary
  /// outcomes, not failures: most of a steady-state run is `ALREADY_STORED`.
  public enum Skipped {
    NO_VERSION_IN_TAG("tags naming no version"),
    OUTSIDE_SATISFY("outside satisfy"),
    ALREADY_STORED("already catalogued"),
    BEFORE_CUTOFF("before the cutoff"),
    UNREADABLE_ARCHIVE("unreadable archives"),
    REFUSED_DOWNLOAD("refused downloads"),
    DIGEST_DISAGREES("digests the catalog disagrees with");

    private final String description;

    Skipped(String description) {
      this.description = description;
    }

    public String description() {
      return description;
    }
  }

  private final AtomicInteger extensions = new AtomicInteger();
  private final AtomicInteger failedExtensions = new AtomicInteger();
  private final AtomicInteger versionsAdded = new AtomicInteger();
  private final AtomicInteger catalogsWritten = new AtomicInteger();

  /// Every key is present from the start, so the counters are only ever read and incremented and
  /// the map itself is never written to from more than one thread.
  private final Map<Skipped, AtomicInteger> skipped = new EnumMap<>(Skipped.class);

  public RunSummary() {
    for (var reason : Skipped.values()) {
      skipped.put(reason, new AtomicInteger());
    }
  }

  public void extensionScanned() {
    extensions.incrementAndGet();
  }

  public void extensionFailed() {
    failedExtensions.incrementAndGet();
  }

  public void versionAdded() {
    versionsAdded.incrementAndGet();
  }

  public void versionSkipped(Skipped reason) {
    skipped.get(reason).incrementAndGet();
  }

  public void catalogWritten() {
    catalogsWritten.incrementAndGet();
  }

  public int exitCode() {
    if (failedExtensions.get() == 0) {
      return EVERYTHING_SUCCEEDED;
    }

    return failedExtensions.get() < extensions.get() ? SOME_EXTENSIONS_FAILED : NOTHING_SUCCEEDED;
  }

  /// One line, on the way out of every run, whatever the outcome was. Built by hand rather than
  /// with a log pattern, because the pattern syntax formats numbers by locale and eats apostrophes.
  public String line() {
    var totalSkipped = skipped.values().stream().mapToInt(AtomicInteger::get).sum();

    return "Scanned "
        + extensions.get()
        + " extensions, "
        + failedExtensions.get()
        + " of them failed: "
        + versionsAdded.get()
        + " versions added, "
        + totalSkipped
        + " skipped"
        + reasons()
        + ", "
        + catalogsWritten.get()
        + " repo.json written";
  }

  private String reasons() {
    var listed =
        skipped.entrySet().stream()
            .filter(counted -> counted.getValue().get() > 0)
            .map(counted -> counted.getValue().get() + " " + counted.getKey().description())
            .collect(Collectors.joining(", "));

    return listed.isEmpty() ? "" : " (" + listed + ")";
  }
}
