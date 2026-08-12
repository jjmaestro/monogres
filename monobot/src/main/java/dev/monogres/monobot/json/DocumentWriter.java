package dev.monogres.monobot.json;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/// Puts a file where a later run will read it, whole or not at all.
///
/// Every file monobot writes is read back by the run after it: `repo.json` is the catalog a run
/// merges into, and the cache's own records are what let it skip a download. A write that stops
/// partway leaves a document that is neither the old one nor the new one, and that stops the entry
/// for good, since deleting the remains by hand forfeits everything they recorded.
@ApplicationScoped
public class DocumentWriter {
  private static final String SUFFIX_TEMPORARY = ".tmp";

  @Inject ObjectMapper objectMapper;

  private interface Content {
    void writeTo(Path written) throws IOException;
  }

  /// A JSON document as the catalog spells it, which is what a run compares against a committed
  /// file as much as what it writes to one.
  public String render(Object document) {
    return CatalogPrinter.print(objectMapper.valueToTree(document));
  }

  /// A JSON document, laid out the way the catalog is written.
  public void write(Path directory, String filename, Object document) {
    var printed = render(document);

    put(directory, filename, written -> Files.writeString(written, printed));
  }

  /// Content that is already a document, such as a file taken out of an archive, written as it
  /// stands.
  public void writeRaw(Path directory, String filename, byte[] content) {
    put(directory, filename, written -> Files.write(written, content));
  }

  /// Written beside the destination and then moved onto it, so what is there is either the whole
  /// previous file or the whole new one.
  ///
  /// The temporary file is in the same directory because an atomic move is a rename, and a rename
  /// does not cross filesystems.
  private void put(Path directory, String filename, Content content) {
    try {
      Files.createDirectories(directory);
      var written = Files.createTempFile(directory, filename, SUFFIX_TEMPORARY);
      try {
        content.writeTo(written);
        Files.move(written, directory.resolve(filename), StandardCopyOption.ATOMIC_MOVE);
      } finally {
        Files.deleteIfExists(written);
      }
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }
}
