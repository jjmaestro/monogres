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
  public static final String POSTGRES_CONTROL_FILE_EXTENSION = ".control";

  // Defensive programming. We should never expect files this large
  private static final int MAX_SIZE_BYTES_PGXN_META_JSON = 16 * 1_024;
  private static final int MAX_SIZE_BYTES_POSTGRES_CONTROL = 1 * 1_024;

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

  private byte[] extractFromArchive(
      TarArchiveInputStream tarIn, TarArchiveEntry entry, int maxSizeBytes) {
    if (entry.getRealSize() > maxSizeBytes) {
      throw new RuntimeException(
          MessageFormat.format(
              "Entry {0} too large ({1} bytes)", entry.getName(), entry.getRealSize()));
    }

    try {
      return extractTarEntryBytes(tarIn);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }

  private MetadataContext extractPostgresControlFromArchive(
      Version version, TarArchiveInputStream tarIn, TarArchiveEntry entry, Metadata metadata) {
    var metadataContext =
        metadata.containsKey(POSTGRES_CONTROL_FILE_EXTENSION)
            ? metadata.get(POSTGRES_CONTROL_FILE_EXTENSION)
            : new MetadataContext();

    var controlBytes = extractFromArchive(tarIn, entry, MAX_SIZE_BYTES_POSTGRES_CONTROL);
    var control = Control.fromBytes(controlBytes);
    try {
      // It is simpler to use mapper.readTree(control). But it does not respect null serialization
      // preferences
      var controlJsonNode = objectMapper.readTree(objectMapper.writeValueAsString(control));
      metadataContext.put(version.normalize(), controlJsonNode);
    } catch (JsonProcessingException e) {
      throw new RuntimeException(e);
    }

    return metadataContext;
  }

  private MetadataContext extractMetaJsonFromArchive(
      Version version, TarArchiveInputStream tarIn, TarArchiveEntry entry, Metadata metadata) {
    var metadataContext =
        metadata.containsKey(PGXN_META_JSON_FILENAME)
            ? metadata.get(PGXN_META_JSON_FILENAME)
            : new MetadataContext();

    try {
      var jsonNode =
          objectMapper.readTree(extractFromArchive(tarIn, entry, MAX_SIZE_BYTES_PGXN_META_JSON));
      metadataContext.put(version.normalize(), jsonNode);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }

    return metadataContext;
  }

  public void addFromArchive(String name, Version version, Path archivePath, Metadata metadata) {
    try (var fis = new FileInputStream(archivePath.toFile());
        var bis = new BufferedInputStream(fis);
        var gzipIn = new GzipCompressorInputStream(bis);
        var tarIn = new TarArchiveInputStream(gzipIn)) {
      TarArchiveEntry entry;

      while ((entry = tarIn.getNextEntry()) != null) {
        var entryFile = new File(entry.getName());
        var fileName = entryFile.getName();
        if (PGXN_META_JSON_FILENAME.equals(fileName)) {
          var metadataContext = extractMetaJsonFromArchive(version, tarIn, entry, metadata);
          metadata.put(PGXN_META_JSON_FILENAME, metadataContext);
        } else if (fileName.equals(name + POSTGRES_CONTROL_FILE_EXTENSION)) {
          var metadataContext = extractPostgresControlFromArchive(version, tarIn, entry, metadata);
          metadata.put(POSTGRES_CONTROL_FILE_EXTENSION, metadataContext);
        }
      }
    } catch (FileNotFoundException e) {
      throw new RuntimeException(e);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }
}
