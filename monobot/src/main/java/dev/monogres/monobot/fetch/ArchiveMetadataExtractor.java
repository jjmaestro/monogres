package dev.monogres.monobot.fetch;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.Metadata;
import dev.monogres.monobot.config.MetadataContext;
import dev.monogres.monobot.config.output.Version;
import dev.monogres.monobot.postgres.extensions.control.Control;
import jakarta.inject.Inject;
import jakarta.inject.Singleton;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Path;
import java.time.Instant;
import org.apache.commons.compress.archivers.tar.TarArchiveEntry;
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream;
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream;
import org.jboss.logging.Logger;

@Singleton
public class ArchiveMetadataExtractor {
  private static final Logger LOG = Logger.getLogger(ArchiveMetadataExtractor.class);

  public static final String PGXN_META_JSON_FILENAME = "META.json";
  public static final String POSTGRES_CONTROL_FILE_EXTENSION = ".control";

  // What one entry is allowed to be. Generous, because the cost of being wrong is asymmetric: an
  // entry over the bound is read past rather than parsed, so a bound set too low quietly leaves a
  // version's metadata out of the catalog.
  private static final int MAX_SIZE_BYTES_PGXN_META_JSON = 1_024 * 1_024;
  private static final int MAX_SIZE_BYTES_POSTGRES_CONTROL = 64 * 1_024;

  // What a whole archive is allowed to expand to. Nothing between the socket and this walk caps
  // anything, and the walk reads every entry, so a small archive declaring an enormous one costs
  // the CPU and the wall clock to walk it, inside an ordered block where it serialises behind
  // itself. A Postgres extension's source tree is nowhere near either bound.
  private static final long MAX_DECOMPRESSED_BYTES = 256L * 1_024 * 1_024;
  private static final int MAX_ENTRIES = 50_000;

  @Inject ObjectMapper objectMapper;

  private byte[] extractTarEntryBytes(TarArchiveInputStream tarIn) throws IOException {
    var out = new ByteArrayOutputStream();
    var buffer = new byte[8192];
    int len;
    while ((len = tarIn.read(buffer)) != -1) {
      out.write(buffer, 0, len);
    }

    return out.toByteArray();
  }

  /// The entry's bytes, or null when it is larger than one of its kind is allowed to be. Null
  /// rather than a throw, because the entry answers for the metadata and not for the version: the
  /// version, its commit and its digest are all sound whatever this file turned out to be.
  private byte[] extractFromArchive(
      TarArchiveInputStream tarIn, TarArchiveEntry entry, int maxSizeBytes) {
    if (entry.getRealSize() > maxSizeBytes) {
      LOG.warnv(
          "Entry {0} is larger than the {1} bytes allowed, so it is left out",
          entry.getName(), String.valueOf(maxSizeBytes));

      return null;
    }

    try {
      return extractTarEntryBytes(tarIn);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }

  private MetadataContext controlContext(Version version, byte[] controlBytes, Metadata metadata) {
    var metadataContext =
        metadata.containsKey(POSTGRES_CONTROL_FILE_EXTENSION)
            ? metadata.get(POSTGRES_CONTROL_FILE_EXTENSION)
            : new MetadataContext();

    var control = Control.fromBytes(controlBytes);
    try {
      // It is simpler to use mapper.readTree(control). But it does not respect null serialization
      // preferences
      var controlJsonNode = objectMapper.readTree(objectMapper.writeValueAsString(control));
      metadataContext.put(version.version(), controlJsonNode);
    } catch (JsonProcessingException e) {
      throw new RuntimeException(e);
    }

    return metadataContext;
  }

  private MetadataContext metaJsonContext(Version version, byte[] metaJson, Metadata metadata) {
    var metadataContext =
        metadata.containsKey(PGXN_META_JSON_FILENAME)
            ? metadata.get(PGXN_META_JSON_FILENAME)
            : new MetadataContext();

    try {
      var jsonNode = objectMapper.readTree(metaJson);
      metadataContext.put(version.version(), jsonNode);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }

    return metadataContext;
  }

  /// Everything one archive answers for, taken in one pass over it.
  ///
  /// `lastModified` is the newest modification time the archive records for any entry, which is
  /// what a forge writes into the archive it serves and the only date available without asking the
  /// forge a second question: the tag listing carries commit ids and nothing else. An archive with
  /// no entries reports [Instant#MIN], which no cutoff accepts.
  public record ArchiveContents(Instant lastModified, byte[] metaJson, byte[] control) {}

  /// Opening the archive is its own method so a test can count how often one is read. Gunzipping
  /// and walking a whole tarball is the most expensive thing this program does per version, and it
  /// runs inside an ordered `executeBlocking`, so it serialises behind itself.
  InputStream open(Path archivePath) throws IOException {
    return new BufferedInputStream(new FileInputStream(archivePath.toFile()));
  }

  /// The entry that answers for a version, out of however many of that name the archive holds. An
  /// extension that ships a test fixture ships a second `{name}.control`, and which entry a forge
  /// wrote last is the forge's decision, so the choice is a rule: closest to the root, and on a
  /// tie the lower path. The name alone is not one, because it is the same name either way.
  private record Chosen(String path, byte[] bytes) {
    private static int depth(String path) {
      return (int) path.chars().filter(character -> character == '/').count();
    }

    boolean losesTo(String candidate) {
      var byDepth = Integer.compare(depth(candidate), depth(path));

      return byDepth != 0 ? byDepth < 0 : candidate.compareTo(path) < 0;
    }
  }

  private static Chosen choose(Chosen chosen, TarArchiveEntry entry, byte[] bytes) {
    if (bytes == null) {
      return chosen;
    }

    return chosen == null || chosen.losesTo(entry.getName())
        ? new Chosen(entry.getName(), bytes)
        : chosen;
  }

  public ArchiveContents read(String name, Path archivePath) {
    Chosen metaJson = null;
    Chosen control = null;
    var lastModified = Instant.MIN;

    try (var raw = open(archivePath);
        var gzipIn = new GzipCompressorInputStream(raw);
        var tarIn = new TarArchiveInputStream(gzipIn)) {
      TarArchiveEntry entry;
      var entries = 0;
      var declaredBytes = 0L;

      while ((entry = tarIn.getNextEntry()) != null) {
        entries++;
        declaredBytes += Math.max(0L, entry.getSize());
        if (entries > MAX_ENTRIES || declaredBytes > MAX_DECOMPRESSED_BYTES) {
          throw new RuntimeException(
              "Archive "
                  + archivePath
                  + " expands past the "
                  + MAX_ENTRIES
                  + " entries and "
                  + MAX_DECOMPRESSED_BYTES
                  + " bytes a source archive is allowed");
        }

        var modified = entry.getLastModifiedTime().toInstant();
        if (modified.isAfter(lastModified)) {
          lastModified = modified;
        }

        var fileName = new File(entry.getName()).getName();
        if (PGXN_META_JSON_FILENAME.equals(fileName)) {
          metaJson =
              choose(
                  metaJson, entry, extractFromArchive(tarIn, entry, MAX_SIZE_BYTES_PGXN_META_JSON));
        } else if (fileName.equals(name + POSTGRES_CONTROL_FILE_EXTENSION)) {
          control =
              choose(
                  control,
                  entry,
                  extractFromArchive(tarIn, entry, MAX_SIZE_BYTES_POSTGRES_CONTROL));
        }
      }
    } catch (IOException e) {
      throw new RuntimeException("Error while reading " + archivePath, e);
    }

    return new ArchiveContents(
        lastModified,
        metaJson == null ? null : metaJson.bytes(),
        control == null ? null : control.bytes());
  }

  public void addContents(Version version, ArchiveContents contents, Metadata metadata) {
    if (contents.metaJson() != null) {
      metadata.put(
          PGXN_META_JSON_FILENAME, metaJsonContext(version, contents.metaJson(), metadata));
    }
    if (contents.control() != null) {
      metadata.put(
          POSTGRES_CONTROL_FILE_EXTENSION, controlContext(version, contents.control(), metadata));
    }
  }
}
