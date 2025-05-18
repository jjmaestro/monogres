package dev.monogres.monobot.fetch;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.Metadata;
import dev.monogres.monobot.config.MetadataContext;
import dev.monogres.monobot.config.output.Version;
import jakarta.inject.Inject;
import jakarta.inject.Singleton;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.file.Path;
import java.text.MessageFormat;
import org.apache.commons.compress.archivers.tar.TarArchiveEntry;
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream;
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream;

@Singleton
public class ArchiveMetadataExtractor {
  public static final String PGXN_META_JSON_FILENAME = "META.json";

  // Defensive programming. We should never expect a META.json this large
  private static final int PGXN_META_JSON_MAX_SIZE_BYTES = 16 * 1_024;

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

  private JsonNode extractMetaJsonFromArchive(TarArchiveInputStream tarIn, String name, long size) {
    if (size > PGXN_META_JSON_MAX_SIZE_BYTES) {
      throw new RuntimeException(
          MessageFormat.format("META.json entry {0} too large ({1} bytes)", name, size));
    }

    try {
      return objectMapper.readTree(extractTarEntryBytes(tarIn));
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }

  public void addFromArchive(Version version, Path archivePath, Metadata metadata) {
    try (var fis = new FileInputStream(archivePath.toFile());
        var bis = new BufferedInputStream(fis);
        var gzipIn = new GzipCompressorInputStream(bis);
        var tarIn = new TarArchiveInputStream(gzipIn)) {
      TarArchiveEntry entry;

      while ((entry = tarIn.getNextEntry()) != null) {
        var entryFile = new File(entry.getName());
        if (PGXN_META_JSON_FILENAME.equals(entryFile.getName())) {
          var metaJsonSize = entry.getRealSize();

          var metaJson = extractMetaJsonFromArchive(tarIn, entry.getName(), metaJsonSize);
          var metadataContext =
              metadata.containsKey(PGXN_META_JSON_FILENAME)
                  ? metadata.get(PGXN_META_JSON_FILENAME)
                  : new MetadataContext();
          metadataContext.put(version.normalize(), metaJson);
          metadata.put(PGXN_META_JSON_FILENAME, metadataContext);
        }
      }
    } catch (FileNotFoundException e) {
      throw new RuntimeException(e);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }
}
