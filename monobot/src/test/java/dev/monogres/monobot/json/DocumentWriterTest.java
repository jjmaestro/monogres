package dev.monogres.monobot.json;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// What a reader can find at a path while it is being written. Every file monobot writes is an
/// input to the run after it: `repo.json` is the catalog a run merges into, and the cache's records
/// are what let a run skip a download. A file that is neither the old one nor a whole new one stops
/// that entry for good, since deleting the remains by hand forfeits everything they recorded.
///
/// No container here: [DocumentWriter]'s injection point is a package-private field, and writing
/// needs only the mapper.
class DocumentWriterTest {
  private static final String STORED =
      """
      {"sources": {}, "versions": {}, "metadata": {}, "version": 1}\
      """;

  /// A document the mapper reads part of and then refuses, which is every way a write can fail
  /// short of the disk itself.
  public static class HalfWritable {
    public String getEarly() {
      return "read";
    }

    public String getLate() {
      throw new IllegalStateException("the write stopped here");
    }
  }

  private Path directory;
  private Path target;

  @BeforeEach
  void setUp() throws Exception {
    directory = Files.createTempDirectory("monobot-write");
    target = directory.resolve("repo.json");
    Files.writeString(target, STORED);
  }

  @AfterEach
  void tearDown() throws Exception {
    try (var walk = Files.walk(directory)) {
      for (var path : walk.sorted(Comparator.reverseOrder()).toList()) {
        Files.delete(path);
      }
    }
  }

  private static DocumentWriter documentWriter() {
    var documentWriter = new DocumentWriter();
    documentWriter.objectMapper = new ObjectMapper();

    return documentWriter;
  }

  @Test
  void writeThatStopsPartwayLeavesTheStoredDocumentAlone() throws Exception {
    assertThrows(
        RuntimeException.class,
        () -> documentWriter().write(directory, "repo.json", new HalfWritable()));

    assertEquals(STORED, Files.readString(target));
  }

  @Test
  void writeThatStopsPartwayLeavesNothingBehindInTheDirectory() throws Exception {
    assertThrows(
        RuntimeException.class,
        () -> documentWriter().write(directory, "repo.json", new HalfWritable()));

    try (var entries = Files.list(directory)) {
      assertEquals(List.of(target), entries.toList(), "the write left a file beside repo.json");
    }
  }

  @Test
  void completedWriteReplacesTheStoredDocument() throws Exception {
    documentWriter().write(directory, "repo.json", List.of("replaced"));

    assertEquals("[\"replaced\"]\n", Files.readString(target));
    try (var entries = Files.list(directory)) {
      assertTrue(entries.toList().size() == 1, "the write left a file beside repo.json");
    }
  }

  /// A control file or a META.json taken out of an archive, which is already a document and is kept
  /// as the archive spelled it: trailing whitespace, line endings and all.
  @Test
  void contentThatIsAlreadyWrittenGoesOutByteForByte() throws Exception {
    var carried = "default_version = '1.0'\r\n\r\n".getBytes(StandardCharsets.UTF_8);

    documentWriter().writeRaw(directory, "fixture.control", carried);

    assertArrayEquals(carried, Files.readAllBytes(directory.resolve("fixture.control")));
  }
}
