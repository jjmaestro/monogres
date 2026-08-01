package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import dev.monogres.monobot.digest.DigestUtils;
import io.vertx.core.Vertx;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HexFormat;
import java.util.Random;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// Where the digest runs, and how large an archive it can answer for.
///
/// Digesting means reading every byte, and the download's continuation runs on whichever thread
/// completed the HTTP future, which for a response is an event loop. An event loop that is
/// digesting is an event loop that is serving no other connection, so the work belongs on a worker.
///
/// Reading a block at a time is what leaves the size unbounded, and the digest is the one value a
/// downstream build pins on. A mapping is addressed by an int, so an archive over 2 GiB would raise
/// an IllegalArgumentException, which is not an IOException and so reports itself as a stack trace
/// rather than as the intended message.
///
/// No Quarkus here: [SourceArchive]'s injection points are package-private fields, so a plain
/// instance with a real Vert.x is enough, and the digest is reached without a network call.
class SourceArchiveDigestTest {
  private static final String EVENT_LOOP_THREAD_PREFIX = "vert.x-eventloop";

  private static final int OVER_ONE_READ = 5 * 1024 * 1024;
  private static final long OVER_THE_MAPPING_CEILING = (1L << 31) + (1L << 20);
  private static final long RANDOM_SEED = 20260809L;

  private Vertx vertx;
  private Path directory;
  private Path archive;
  private byte[] bytes;

  @BeforeEach
  void setUp() throws Exception {
    vertx = Vertx.vertx();
    directory = Files.createTempDirectory("monobot-digest");
    bytes = PipelineFixture.archive("fixture-aa1/fixture.control", "default_version = '1.0.0'", 0L);
    archive = directory.resolve("fixture.tar.gz");
    Files.write(archive, bytes);
  }

  @AfterEach
  void tearDown() throws Exception {
    PipelineFixture.deleteRecursively(directory);
    vertx.close().toCompletionStage().toCompletableFuture().get(30, TimeUnit.SECONDS);
  }

  /// Records the thread the digest actually ran on. Overriding rather than mocking keeps the real
  /// computation, so the returned value is still checked against the bytes on disk.
  private SourceArchive recordingSourceArchive(AtomicReference<String> thread) {
    var sourceArchive =
        new SourceArchive() {
          @Override
          String sha256(Path path) {
            thread.set(Thread.currentThread().getName());
            return super.sha256(path);
          }
        };
    sourceArchive.vertx = vertx;

    return sourceArchive;
  }

  @Test
  void digestingDoesNotRunOnTheEventLoopThatAskedForIt() throws Exception {
    var digestThread = new AtomicReference<String>();
    var callerThread = new AtomicReference<String>();
    var result = new AtomicReference<String>();
    var sourceArchive = recordingSourceArchive(digestThread);
    var done = new CountDownLatch(1);

    vertx.runOnContext(
        v -> {
          callerThread.set(Thread.currentThread().getName());
          sourceArchive
              .digest(archive)
              .onComplete(
                  outcome -> {
                    result.set(outcome.result());
                    done.countDown();
                  });
        });

    assertTrue(done.await(30, TimeUnit.SECONDS), "the digest never completed");
    assertEquals(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)), result.get());
    assertTrue(
        callerThread.get().startsWith(EVENT_LOOP_THREAD_PREFIX),
        "the test has to ask from an event loop for this to mean anything, got "
            + callerThread.get());
    assertFalse(
        digestThread.get().startsWith(EVENT_LOOP_THREAD_PREFIX),
        "the digest ran on an event loop: " + digestThread.get());
  }

  /// More than one read's worth, so what the digest covers is every block of the file rather than
  /// the first one.
  @Test
  void digestsFilesLargerThanOneRead() throws Exception {
    var large = new byte[OVER_ONE_READ];
    new Random(RANDOM_SEED).nextBytes(large);
    var target = directory.resolve("large.tar.gz");
    Files.write(target, large);

    assertEquals(DigestUtils.sha256sum(ByteBuffer.wrap(large)), new SourceArchive().sha256(target));
  }

  /// Sparse, so the file is over 2 GiB long and occupies no blocks. The digest is compared against
  /// one taken here the same way, which is the only reference available for a file this size.
  @Test
  void digestsFilesOverTwoGibibytes() throws Exception {
    var target = directory.resolve("huge.tar.gz");
    try (var file = new RandomAccessFile(target.toFile(), "rw")) {
      file.setLength(OVER_THE_MAPPING_CEILING);
    }
    assumeTrue(
        Files.size(target) == OVER_THE_MAPPING_CEILING,
        "the filesystem would not take a sparse file this long");

    assertEquals(zeroDigest(OVER_THE_MAPPING_CEILING), new SourceArchive().sha256(target));
  }

  private static String zeroDigest(long length) {
    var digest = DigestUtils.getSha256MessageDigest();
    var zeros = new byte[OVER_ONE_READ];
    for (var written = 0L; written < length; written += zeros.length) {
      digest.update(zeros, 0, (int) Math.min(zeros.length, length - written));
    }

    return HexFormat.of().formatHex(digest.digest());
  }
}
