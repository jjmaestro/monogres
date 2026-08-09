package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import dev.monogres.monobot.digest.DigestUtils;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// The real download path, driven against [DownloadHarness] rather than a forge: where the request
/// goes, what makes it fail, and what it leaves behind on disk when it does.
class SourceArchiveDownloadTest {
  private static final Duration DOWNLOAD_TIMEOUT = Duration.ofSeconds(10);
  private static final int RATE_LIMITED = 429;
  private static final int NOT_FOUND = 404;
  private static final int STALE_FILE_BYTES = 64 * 1024;
  private static final int FAILED_ATTEMPTS = 64;
  private static final Path PROC_SELF_FD = Path.of("/proc/self/fd");

  private DownloadHarness forge;
  private Path target;

  @BeforeEach
  void setUp() throws Exception {
    forge = new DownloadHarness();
    target = Files.createTempDirectory("monobot-download").resolve("archive.tar.gz");
  }

  @AfterEach
  void tearDown() throws Exception {
    forge.close();
    PipelineFixture.deleteRecursively(target.getParent());
  }

  @Test
  void downloadsFromThePortTheUrlNames() throws Exception {
    var body = PipelineFixture.archive("fixture-aa1/fixture.control", "default_version = '1'", 0L);
    forge.answerWith(body);

    var sha256 =
        DownloadHarness.await(
            forge.sourceArchive(DOWNLOAD_TIMEOUT).sha256UrlFile(forge.url("/archive"), target));

    assertArrayEquals(body, Files.readAllBytes(target));
    assertEquals(DigestUtils.sha256sum(ByteBuffer.wrap(body)), sha256);
  }

  /// The failure an anonymous caller actually meets. Both forges rate limit one, and the answer is
  /// a status code with a JSON explanation, which is a perfectly good file and a useless archive.
  @Test
  void rateLimitingFailsTheDownload() throws Exception {
    forge.answerWithStatus(RATE_LIMITED, "{\"message\": \"API rate limit exceeded\"}");

    var failure =
        DownloadHarness.awaitFailure(
            forge.sourceArchive(DOWNLOAD_TIMEOUT).sha256UrlFile(forge.url("/archive"), target));

    assertTrue(
        failure.getMessage().contains(String.valueOf(RATE_LIMITED)),
        "the failure does not name the status code: " + failure.getMessage());
    assertTrue(
        failure.getMessage().contains(forge.url("/archive").toString()),
        "the failure does not name the URL: " + failure.getMessage());
    assertEquals(0L, sizeOf(target), "the error body was written to the archive path");
  }

  @Test
  void missingArchiveFailsTheDownload() throws Exception {
    forge.answerWithStatus(NOT_FOUND, "no such repository");

    var failure =
        DownloadHarness.awaitFailure(
            forge.sourceArchive(DOWNLOAD_TIMEOUT).sha256UrlFile(forge.url("/archive"), target));

    assertTrue(
        failure.getMessage().contains(String.valueOf(NOT_FOUND)),
        "the failure does not name the status code: " + failure.getMessage());
    assertEquals(0L, sizeOf(target), "the error body was written to the archive path");
  }

  /// A retry over a longer file left by an earlier attempt. Writing starts at offset 0 either way,
  /// so what decides the digest is whether the tail of the older file is still there when the
  /// whole file is read back. `sha256` is the one value a downstream build pins on, so a stale
  /// tail turns an interrupted run from loudly wrong into silently wrong.
  @Test
  void retryDigestsTheResponseNotTheFileItReplaced() throws Exception {
    Files.createDirectories(target.getParent());
    Files.write(target, new byte[STALE_FILE_BYTES]);
    var body = PipelineFixture.archive("fixture-aa1/fixture.control", "default_version = '1'", 0L);
    forge.answerWith(body);

    var sha256 =
        DownloadHarness.await(
            forge.sourceArchive(DOWNLOAD_TIMEOUT).sha256UrlFile(forge.url("/archive"), target));

    assertArrayEquals(body, Files.readAllBytes(target));
    assertEquals(DigestUtils.sha256sum(ByteBuffer.wrap(body)), sha256);
  }

  /// The archive file is opened before the request is even built, and only the body codec's end
  /// path closes it. A connect failure never builds a codec at all, so nothing closes anything.
  /// One descriptor per failed download, held for the rest of the run, is what eventually throws
  /// EMFILE out of the next open, and an open that throws leaks a download permit with it.
  @Test
  void failedDownloadsCloseTheFilesTheyOpened() throws Exception {
    assumeTrue(Files.isDirectory(PROC_SELF_FD), "counting descriptors needs /proc");
    var refused = DownloadHarness.closedPort();
    var sourceArchive = forge.sourceArchive(DOWNLOAD_TIMEOUT);

    for (var attempt = 0; attempt < FAILED_ATTEMPTS; attempt++) {
      DownloadHarness.awaitFailure(
          sourceArchive.sha256UrlFile(DownloadHarness.url(refused, "/archive"), target));
    }

    assertEquals(0L, openDescriptorsFor(target), "the archive file is still open");
  }

  @Test
  void refusedStatusClosesTheFileItOpened() throws Exception {
    assumeTrue(Files.isDirectory(PROC_SELF_FD), "counting descriptors needs /proc");
    forge.answerWithStatus(RATE_LIMITED, "{\"message\": \"API rate limit exceeded\"}");

    DownloadHarness.awaitFailure(
        forge.sourceArchive(DOWNLOAD_TIMEOUT).sha256UrlFile(forge.url("/archive"), target));

    assertEquals(0L, openDescriptorsFor(target), "the archive file is still open");
  }

  @Test
  void transferCutInTheMiddleClosesTheFileItOpened() throws Exception {
    assumeTrue(Files.isDirectory(PROC_SELF_FD), "counting descriptors needs /proc");
    var body = PipelineFixture.archive("fixture-aa1/fixture.control", "default_version = '1'", 0L);
    forge.answerTruncated(body, body.length / 2);

    DownloadHarness.awaitFailure(
        forge.sourceArchive(DOWNLOAD_TIMEOUT).sha256UrlFile(forge.url("/archive"), target));

    assertEquals(0L, openDescriptorsFor(target), "the archive file is still open");
  }

  /// How many descriptors this process holds on one file. `/proc/self/fd` names them, and each
  /// entry is a symlink to the file it refers to.
  private static long openDescriptorsFor(Path path) throws Exception {
    if (!Files.exists(path)) {
      return 0L;
    }
    var real = path.toRealPath();
    try (var descriptors = Files.list(PROC_SELF_FD)) {
      return descriptors.filter(descriptor -> refersTo(descriptor, real)).count();
    }
  }

  private static boolean refersTo(Path descriptor, Path path) {
    try {
      return Files.readSymbolicLink(descriptor).equals(path);
    } catch (IOException e) {
      // Closed while the directory was being read, so it refers to nothing now.
      return false;
    }
  }

  private static long sizeOf(Path path) throws Exception {
    return Files.exists(path) ? Files.size(path) : 0L;
  }
}
