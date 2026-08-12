package dev.monogres.monobot.fetch;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.output.Version;
import dev.monogres.monobot.digest.DigestUtils;
import dev.monogres.monobot.fetch.ArchiveMetadataExtractor.ArchiveContents;
import dev.monogres.monobot.fetch.SourceArchive.Download;
import dev.monogres.monobot.fetch.SourceArchive.Validators;
import dev.monogres.monobot.json.DocumentWriter;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.IOException;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Optional;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

/// Every archive the catalog is built from, kept where it can be read again.
///
/// The tree mirrors the catalog and adds a level per version, so the path an archive is at names
/// the entry and the version it answers for:
///
/// ```
/// <cacheDir>/extensions/pgvector/0.8.2/pgvector-0.8.2.tar.gz
/// <cacheDir>/extensions/pgvector/0.8.2/fetch.json
/// <cacheDir>/extensions/pgvector/0.8.2/vector.control
/// <cacheDir>/extensions/pgvector/0.8.2/META.json
/// ```
///
/// The archives are the raw data every value in `repo.json` is derived from, and re-fetching them
/// costs gigabytes against sources that rate limit anonymous callers. So nothing here is ever
/// deleted, and a run that finds an archive it can answer for asks for nothing.
@ApplicationScoped
public class ArchiveCache {
  private static final Logger LOG = Logger.getLogger(ArchiveCache.class);

  private static final String FILENAME_FETCH_JSON = "fetch.json";
  private static final String FILENAME_META_JSON = "META.json";
  private static final String SUFFIX_CONTROL = ".control";

  /// How much of a cached archive is checked before a run answers from it.
  public enum Verify {
    /// The file's length against the length recorded for it. One stat call per version, and it
    /// catches every way a write stops partway.
    SIZE,
    /// The file's digest against the digest recorded for it. Exact, and it reads the whole cache
    /// off the disk on every run.
    DIGEST,
    /// Nothing. The record is taken at its word.
    NONE
  }

  @ConfigProperty(name = "cacheDir")
  String cacheDir;

  @ConfigProperty(name = "verifyCache")
  Verify verifyCache;

  @ConfigProperty(name = "refreshCache")
  boolean refreshCache;

  @Inject Vertx vertx;

  @Inject ObjectMapper objectMapper;

  @Inject SourceArchive sourceArchive;

  @Inject DownloadLimiter downloadLimiter;

  @Inject DocumentWriter documentWriter;

  /// One version's archive and the digest the catalog records for it.
  public record Cached(Path archive, String sha256) {}

  /// Where one version of one entry is kept. `entry` is the entry's path relative to the catalog,
  /// so an entry's cache is next to where its `repo.json` is written.
  public Path directory(Path entry, Version version) {
    return Path.of(cacheDir).resolve(entry).resolve(version.version());
  }

  private static String basename(URL url) {
    var path = url.getPath();

    return path.substring(path.lastIndexOf('/') + 1);
  }

  /// The archive one version names, fetched only if the cache cannot answer for it already.
  public Future<Cached> archive(Path entry, Version version, URL url) {
    var directory = directory(entry, version);
    var archive = directory.resolve(basename(url));

    // Blocking, because deciding can mean digesting a cached archive, and that is the whole file
    // off the disk on a thread every download's continuation runs on.
    return vertx
        .executeBlocking(() -> usable(directory, archive, url), false)
        .compose(
            usable -> {
              if (usable.isEmpty()) {
                return fetch(directory, archive, url, null);
              }
              if (refreshCache) {
                return fetch(directory, archive, url, usable.get());
              }

              return Future.succeededFuture(new Cached(archive, usable.get().sha256()));
            });
  }

  /// The control file and the PGXN metadata as the archive carried them, kept beside the archive.
  /// The catalog gets these parsed; here they are the bytes, which is what a question about how
  /// they were parsed can be answered against.
  public void storeExtracted(Path directory, String controlStem, ArchiveContents contents) {
    if (contents.control() != null && controlStem != null) {
      documentWriter.writeRaw(directory, controlStem + SUFFIX_CONTROL, contents.control());
    }
    if (contents.metaJson() != null) {
      documentWriter.writeRaw(directory, FILENAME_META_JSON, contents.metaJson());
    }
  }

  /// The record the cache holds for this archive, or empty when it holds none it can answer with.
  /// Ordered so the cheapest disagreement is found first, and every one of them means fetching.
  private Optional<ArchiveRecord> usable(Path directory, Path archive, URL url) {
    var stored = read(directory);

    if (stored == null) {
      return Optional.empty();
    }
    if (!stored.url().equals(url.toString())) {
      LOG.infov("{0} was fetched from {1} and is now named by {2}", archive, stored.url(), url);

      return Optional.empty();
    }
    if (!Files.exists(archive)) {
      LOG.infov("{0} is recorded in the cache and is not there", archive);

      return Optional.empty();
    }

    return switch (verifyCache) {
      case NONE -> Optional.of(stored);
      case SIZE -> sizeAgrees(archive, stored) ? Optional.of(stored) : Optional.empty();
      case DIGEST -> digestAgrees(archive, stored) ? Optional.of(stored) : Optional.empty();
    };
  }

  private boolean sizeAgrees(Path archive, ArchiveRecord stored) {
    try {
      var size = Files.size(archive);
      if (size == stored.size()) {
        return true;
      }
      LOG.warnv("{0} is {1} bytes and {2} were fetched", archive, size, stored.size());
    } catch (IOException e) {
      LOG.warnv(e, "{0} cannot be measured", archive);
    }

    return false;
  }

  /// A cached file that cannot be read is a file the cache cannot answer with, which is the same
  /// outcome as one that disagrees. Digesting reports an I/O error by throwing, and failing the
  /// version over it would refuse to fetch the archive that would replace it.
  private boolean digestAgrees(Path archive, ArchiveRecord stored) {
    try {
      var sha256 = DigestUtils.sha256sum(archive);
      if (sha256.equals(stored.sha256())) {
        return true;
      }
      LOG.warnv("{0} digests to {1} and {2} was fetched", archive, sha256, stored.sha256());
    } catch (RuntimeException e) {
      LOG.warnv(e, "{0} cannot be digested", archive);
    }

    return false;
  }

  /// Asks the source for the archive. With a record in hand the request carries that record's
  /// validators, so a source that still serves the same bytes answers 304 and the cache keeps what
  /// it has.
  private Future<Cached> fetch(Path directory, Path archive, URL url, ArchiveRecord stored) {
    if (stored == null) {
      return downloadLimiter
          .withPermit(() -> sourceArchive.download(url, archive))
          .compose(download -> store(directory, archive, url, download));
    }

    return downloadLimiter
        .withPermit(
            () ->
                sourceArchive.refresh(
                    url, archive, new Validators(stored.etag(), stored.lastModified())))
        .compose(
            answered ->
                answered.isPresent()
                    ? store(directory, archive, url, answered.get())
                    : Future.succeededFuture(new Cached(archive, stored.sha256())));
  }

  /// The record is written only once the archive is on disk and digested, so a directory holding an
  /// archive and no record is a fetch that did not finish and is asked for again.
  private Future<Cached> store(Path directory, Path archive, URL url, Download download) {
    return vertx.executeBlocking(
        () -> {
          documentWriter.write(
              directory,
              FILENAME_FETCH_JSON,
              new ArchiveRecord(
                  url.toString(),
                  download.sha256(),
                  download.size(),
                  download.lastModified(),
                  download.etag(),
                  Instant.now().toString()));

          return new Cached(archive, download.sha256());
        },
        false);
  }

  /// Null when the cache holds no record for this version, and null too when it holds one that
  /// cannot be read: an unreadable record answers for nothing, and the archive it describes is
  /// fetched again rather than the run stopping over it.
  private ArchiveRecord read(Path directory) {
    var record = directory.resolve(FILENAME_FETCH_JSON);

    if (!Files.exists(record)) {
      return null;
    }

    try {
      return objectMapper.readValue(record.toFile(), ArchiveRecord.class);
    } catch (IOException e) {
      LOG.warnv(e, "{0} cannot be read, so what it describes is fetched again", record);

      return null;
    }
  }
}
