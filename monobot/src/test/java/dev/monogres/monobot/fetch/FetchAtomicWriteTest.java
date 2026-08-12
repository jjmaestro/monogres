package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// What a reader of `repo.json` can find there while it is being written. The previous document is
/// an input to the next run, which reads it back and merges into it, so a document that is neither
/// the old one nor a whole new one stops that extension for good: the run that would replace it
/// has to read it first, and deleting it by hand forfeits every sha256 it recorded.
///
/// No container here: [Fetch]'s injection points are package-private fields, and writing needs
/// only the mapper.
class FetchAtomicWriteTest {
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
    PipelineFixture.deleteRecursively(directory);
  }

  private static Fetch fetch() {
    var fetch = new Fetch();
    fetch.objectMapper = new ObjectMapper();

    return fetch;
  }

  @Test
  void writeThatStopsPartwayLeavesTheStoredDocumentAlone() throws Exception {
    assertThrows(
        RuntimeException.class,
        () -> fetch().writeConfigFile(directory, "repo.json", new HalfWritable()));

    assertEquals(STORED, Files.readString(target));
  }

  @Test
  void writeThatStopsPartwayLeavesNothingBehindInTheDirectory() throws Exception {
    assertThrows(
        RuntimeException.class,
        () -> fetch().writeConfigFile(directory, "repo.json", new HalfWritable()));

    try (var entries = Files.list(directory)) {
      assertEquals(List.of(target), entries.toList(), "the write left a file beside repo.json");
    }
  }

  @Test
  void completedWriteReplacesTheStoredDocument() throws Exception {
    fetch().writeConfigFile(directory, "repo.json", List.of("replaced"));

    assertEquals("[\"replaced\"]\n", Files.readString(target));
    try (var entries = Files.list(directory)) {
      assertTrue(entries.toList().size() == 1, "the write left a file beside repo.json");
    }
  }
}
