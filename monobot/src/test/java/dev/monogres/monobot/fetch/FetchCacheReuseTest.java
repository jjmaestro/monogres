package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.digest.DigestUtils;
import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.TagLister;
import dev.monogres.monobot.scan.Scan;
import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.TestProfile;
import jakarta.inject.Inject;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// What the cache spares the sources, and what makes it give up and ask again.
///
/// The archives are the raw data every value in `repo.json` is derived from, and fetching them all
/// again is gigabytes against sources that rate limit anonymous callers. Without a cache the only
/// record of what has been fetched is `repo.json`, which holds digests and no archives, so every
/// run would ask for every archive of every version, at exit 0.
///
/// The versions are pinned, which is what every entry the catalog holds does and what puts the
/// question to the cache at all: a pinned version is offered on every run, so what decides whether
/// its archive is asked for again is the cache and nothing else.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchCacheReuseTest {
  private static final String EXTENSION_DIR = "extensions/fixture";
  private static final String ARCHIVE = "v0.2.0.tar.gz";

  private static final String CONFIG =
      """
      {
        "name": "fixture",
        "sources": {
          "gh": {
            "tag": "v{version}",
            "name": "fixture",
            "strip_prefix": "{name}-{version}",
            "url": "https://github.com/monogres/{name}/archive/refs/tags/{tag}.tar.gz"
          }
        },
        "versions": { "pin": ["0.2.0", "0.1.0"] }
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @Inject ObjectMapper objectMapper;

  private final AtomicInteger downloads = new AtomicInteger();

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    PipelineFixture.writeConfig(EXTENSION_DIR, CONFIG);
    downloads.set(0);

    when(tagLister.getTags(any())).thenReturn(new GitTag[] {});

    when(sourceArchive.download(any(), any()))
        .thenAnswer(
            invocation -> {
              downloads.incrementAndGet();
              Path target = invocation.getArgument(1);

              // Neither a control file nor a META.json, so the archive answers for no metadata.
              return PipelineFixture.served(
                  target, PipelineFixture.archive("fixture-aa1/README.md", "nothing here", 0L));
            });
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  private static Path cached(String version) {
    return PipelineFixture.cached(EXTENSION_DIR, version);
  }

  private ArchiveRecord recordFor(String version) throws Exception {
    return objectMapper.readValue(
        cached(version).resolve("fetch.json").toFile(), ArchiveRecord.class);
  }

  @Test
  void secondRunOverTheSameInputsAsksTheSourceForNothing() throws Exception {
    run();

    assertEquals(2, downloads.get(), "the first run did not fetch both versions");

    downloads.set(0);
    run();

    assertEquals(0, downloads.get(), "the second run fetched archives it already had");
  }

  /// One directory per version, which is what makes the file at a path answer for that version and
  /// nothing else.
  @Test
  void everyFetchedArchiveStaysInTheCache() throws Exception {
    run();

    var entry = PipelineFixture.CACHE_DIR.resolve(EXTENSION_DIR);
    try (var entries = Files.list(entry)) {
      assertEquals(
          List.of("0.1.0", "0.2.0"),
          entries.map(path -> path.getFileName().toString()).sorted().toList());
    }
    assertTrue(Files.exists(cached("0.2.0").resolve(ARCHIVE)), "the archive is not in the cache");
  }

  /// What the next run answers from. Everything it needs is here: which archive the file is, and
  /// enough to tell that it is still whole.
  @Test
  void theRecordBesideAnArchiveSaysWhatWasFetched() throws Exception {
    run();

    var archive = cached("0.2.0").resolve(ARCHIVE);
    var stored = recordFor("0.2.0");

    assertEquals(
        "https://github.com/monogres/fixture/archive/refs/tags/v0.2.0.tar.gz", stored.url());
    assertEquals(
        DigestUtils.sha256sum(ByteBuffer.wrap(Files.readAllBytes(archive))), stored.sha256());
    assertEquals(Files.size(archive), stored.size());
  }

  /// A download that stopped partway, or a copy of the cache that did. The size is the cheapest
  /// thing that says so, and the version is worth more than the request it costs to replace.
  @Test
  void anArchiveThatIsNotTheLengthRecordedForItIsFetchedAgain() throws Exception {
    run();
    downloads.set(0);

    var archive = cached("0.2.0").resolve(ARCHIVE);
    Files.write(archive, new byte[] {0x1f, (byte) 0x8b});

    run();

    assertEquals(1, downloads.get(), "the truncated archive was reused");
    assertEquals(Files.size(archive), recordFor("0.2.0").size());
  }

  /// The record answers for one URL. A template that now names a different archive under the same
  /// version key describes different bytes, and reusing the old ones would put a digest in the
  /// catalog that belongs to a file nothing points at any more.
  @Test
  void anArchiveTheTemplateNoLongerNamesIsFetchedAgain() throws Exception {
    run();
    downloads.set(0);

    var moved = recordFor("0.2.0");
    PipelineFixture.writeRecord(
        cached("0.2.0"),
        objectMapper,
        new ArchiveRecord(
            "https://codeload.github.com/monogres/fixture/tar.gz/v0.2.0",
            moved.sha256(),
            moved.size(),
            null,
            null,
            moved.fetchedAt()));

    run();

    assertEquals(1, downloads.get(), "an archive from another URL was reused");
  }

  /// A record is written only once the archive is on disk and digested. A directory holding an
  /// archive and no record is a fetch that did not finish, whatever the file in it looks like.
  @Test
  void anArchiveWithNoRecordBesideItIsFetchedAgain() throws Exception {
    run();
    downloads.set(0);

    Files.delete(cached("0.2.0").resolve("fetch.json"));

    run();

    assertEquals(1, downloads.get(), "an archive nothing recorded was reused");
  }
}
