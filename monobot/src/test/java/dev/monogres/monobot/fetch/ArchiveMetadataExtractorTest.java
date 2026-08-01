package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.Metadata;
import dev.monogres.monobot.config.output.Version;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.apache.commons.compress.archivers.tar.TarArchiveEntry;
import org.apache.commons.compress.archivers.tar.TarArchiveOutputStream;
import org.apache.commons.compress.compressors.gzip.GzipCompressorOutputStream;
import org.apache.commons.compress.compressors.gzip.GzipParameters;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// Which file in the archive answers for a version. An extension can ship more than one file whose
/// name ends the right way, a checked-in test fixture being the ordinary case, and the order a
/// forge writes its entries in is the forge's decision, so the choice has to be made by a rule
/// rather than by whichever entry the walk reached last.
class ArchiveMetadataExtractorTest {
  private static final Version VERSION = new Version("1.0.0");

  private static final int ONE_LARGE_ENTRY = 32 * 1024 * 1024;
  private static final int OVER_THE_BYTE_BOUND = 9;
  private static final int OVER_THE_ENTRY_BOUND = 50_001;

  private static final String ROOT_CONTROL =
      "default_version = '1.0.0'\ncomment = 'the real one'\n";
  private static final String NESTED_CONTROL =
      "default_version = '0.0.1'\ncomment = 'a test fixture'\n";

  private Path directory;
  private ArchiveMetadataExtractor extractor;

  @BeforeEach
  void setUp() throws Exception {
    directory = Files.createTempDirectory("monobot-extract");
    extractor = new ArchiveMetadataExtractor();
    extractor.objectMapper = new ObjectMapper();
  }

  @AfterEach
  void tearDown() throws Exception {
    PipelineFixture.deleteRecursively(directory);
  }

  private Path archive(Map<String, String> entries) throws Exception {
    var path = directory.resolve(entries.hashCode() + ".tar.gz");
    Files.write(path, PipelineFixture.archive(entries, 0L));

    return path;
  }

  private String commentIn(Path archive) {
    var metadata = new Metadata();
    extractor.addContents(VERSION, extractor.read("fixture", archive), metadata);

    return metadata
        .get(ArchiveMetadataExtractor.POSTGRES_CONTROL_FILE_EXTENSION)
        .get(VERSION.version())
        .get("comment")
        .asText();
  }

  /// The two orders a forge could have written the same two entries in. The rule picks the one
  /// closest to the root, so both archives answer the same way.
  @Test
  void theControlClosestToTheRootWins() throws Exception {
    var rootFirst = new LinkedHashMap<String, String>();
    rootFirst.put("fixture-aa1/fixture.control", ROOT_CONTROL);
    rootFirst.put("fixture-aa1/test/fixtures/fixture.control", NESTED_CONTROL);

    var nestedFirst = new LinkedHashMap<String, String>();
    nestedFirst.put("fixture-aa1/test/fixtures/fixture.control", NESTED_CONTROL);
    nestedFirst.put("fixture-aa1/fixture.control", ROOT_CONTROL);

    assertEquals("the real one", commentIn(archive(rootFirst)));
    assertEquals("the real one", commentIn(archive(nestedFirst)));
  }

  /// Both answers the pipeline needs come out of one pass. Gunzipping and walking a whole tarball
  /// is the most expensive thing this program does per version, and it runs inside an ordered
  /// block, so a second pass serialises behind the first.
  @Test
  void oneReadAnswersForTheCutoffAndTheMetadata() throws Exception {
    var entries = new LinkedHashMap<String, String>();
    entries.put("fixture-aa1/fixture.control", ROOT_CONTROL);
    var archive = archive(entries);

    var counting = new CountingExtractor();
    counting.objectMapper = new ObjectMapper();
    var contents = counting.read("fixture", archive);
    var metadata = new Metadata();
    counting.addContents(VERSION, contents, metadata);

    assertEquals(1, counting.opens.get(), "the archive was read more than once");
    assertEquals(Instant.EPOCH, contents.lastModified());
    assertEquals(
        "the real one",
        metadata
            .get(ArchiveMetadataExtractor.POSTGRES_CONTROL_FILE_EXTENSION)
            .get(VERSION.version())
            .get("comment")
            .asText());
  }

  /// Nothing between the socket and this walk caps anything, and the walk reads every entry, so a
  /// small archive can declare an enormous one and cost the CPU and the wall clock to walk it. The
  /// walk runs inside an ordered block, so it serialises behind itself while it does.
  @Test
  void archiveThatExpandsPastTheBoundIsRefused() throws Exception {
    var archive = directory.resolve("amplified.tar.gz");
    Files.write(archive, compressibleArchive(OVER_THE_BYTE_BOUND, ONE_LARGE_ENTRY));

    var failure = assertThrows(RuntimeException.class, () -> extractor.read("fixture", archive));

    assertTrue(
        failure.getMessage().contains("bytes a source archive is allowed"),
        "the failure does not name the bound: " + failure.getMessage());
  }

  @Test
  void archiveWithMoreEntriesThanTheBoundIsRefused() throws Exception {
    var archive = directory.resolve("many.tar.gz");
    Files.write(archive, compressibleArchive(OVER_THE_ENTRY_BOUND, 0));

    var failure = assertThrows(RuntimeException.class, () -> extractor.read("fixture", archive));

    assertTrue(
        failure.getMessage().contains("entries"),
        "the failure does not name the bound: " + failure.getMessage());
  }

  /// Entries of zeros, which is what makes an archive compress to nothing and expand to a lot.
  private static byte[] compressibleArchive(int entries, int entryBytes) throws Exception {
    var body = new byte[entryBytes];
    var raw = new java.io.ByteArrayOutputStream();
    var gzipParameters = new GzipParameters();
    gzipParameters.setModificationTime(0L);

    try (var gz = new GzipCompressorOutputStream(raw, gzipParameters);
        var tar = new TarArchiveOutputStream(gz)) {
      for (var written = 0; written < entries; written++) {
        var entry = new TarArchiveEntry("fixture-aa1/filler-" + written);
        entry.setSize(body.length);
        entry.setModTime(0L);
        tar.putArchiveEntry(entry);
        tar.write(body);
        tar.closeArchiveEntry();
      }
    }

    return raw.toByteArray();
  }

  private static final class CountingExtractor extends ArchiveMetadataExtractor {
    private final AtomicInteger opens = new AtomicInteger();

    @Override
    InputStream open(Path archivePath) throws IOException {
      opens.incrementAndGet();

      return super.open(archivePath);
    }
  }

  /// Two at the same depth cannot be told apart by depth, so the tie goes to the lower path and
  /// not to the order the entries happen to be in.
  @Test
  void tieAtTheSameDepthGoesToTheLowerPath() throws Exception {
    var oneOrder = new LinkedHashMap<String, String>();
    oneOrder.put("fixture-aa1/second/fixture.control", NESTED_CONTROL);
    oneOrder.put("fixture-aa1/first/fixture.control", ROOT_CONTROL);

    var otherOrder = new LinkedHashMap<String, String>();
    otherOrder.put("fixture-aa1/first/fixture.control", ROOT_CONTROL);
    otherOrder.put("fixture-aa1/second/fixture.control", NESTED_CONTROL);

    assertEquals("the real one", commentIn(archive(oneOrder)));
    assertEquals("the real one", commentIn(archive(otherOrder)));
  }
}
