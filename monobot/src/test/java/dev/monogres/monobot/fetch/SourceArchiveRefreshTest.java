package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.monogres.monobot.digest.DigestUtils;
import dev.monogres.monobot.fetch.SourceArchive.Validators;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// Asking a source about an archive that is already on disk, driven against [DownloadHarness].
///
/// The point of the question is the answer that costs nothing: a source that recognizes its own
/// validator answers 304 and sends no body, which is what makes refreshing a hundred archives
/// affordable. So what matters is that the validators go out, that a 304 is accepted, and that the
/// file already there is untouched by either.
class SourceArchiveRefreshTest {
  private static final Duration DOWNLOAD_TIMEOUT = Duration.ofSeconds(10);
  private static final int NOT_FOUND = 404;
  private static final String ETAG = "\"5f2e1a\"";
  private static final String LAST_MODIFIED = "Wed, 21 Oct 2026 07:28:00 GMT";

  private DownloadHarness forge;
  private Path target;
  private byte[] body;

  @BeforeEach
  void setUp() throws Exception {
    forge = new DownloadHarness();
    target = Files.createTempDirectory("monobot-refresh").resolve("archive.tar.gz");
    body = PipelineFixture.archive("fixture-aa1/fixture.control", "default_version = '1'", 0L);
  }

  @AfterEach
  void tearDown() throws Exception {
    forge.close();
    PipelineFixture.deleteRecursively(target.getParent());
  }

  private static Validators bothValidators() {
    return new Validators(ETAG, LAST_MODIFIED);
  }

  @Test
  void theValidatorsTheCacheHoldsGoOutWithTheRequest() throws Exception {
    forge.answerWith(body);

    DownloadHarness.await(
        forge
            .sourceArchive(DOWNLOAD_TIMEOUT)
            .refresh(forge.url("/archive"), target, bothValidators()));

    var headers = forge.received().getFirst();
    assertEquals(ETAG, headers.get("If-None-Match"));
    assertEquals(LAST_MODIFIED, headers.get("If-Modified-Since"));
  }

  /// A source that offered neither validator leaves the cache with nothing to condition on, and a
  /// header with no value is not one to send.
  @Test
  void nothingToConditionOnSendsNoConditionalHeaders() throws Exception {
    forge.answerWith(body);

    DownloadHarness.await(
        forge
            .sourceArchive(DOWNLOAD_TIMEOUT)
            .refresh(forge.url("/archive"), target, new Validators(null, null)));

    var headers = forge.received().getFirst();
    assertFalse(headers.contains("If-None-Match"), "an empty validator was sent");
    assertFalse(headers.contains("If-Modified-Since"), "an empty validator was sent");
  }

  @Test
  void anUnchangedArchiveIsAnsweredWithoutOne() throws Exception {
    forge.answerWithEtag(ETAG, body);
    Files.createDirectories(target.getParent());
    Files.write(target, body);

    var answered =
        DownloadHarness.await(
            forge
                .sourceArchive(DOWNLOAD_TIMEOUT)
                .refresh(forge.url("/archive"), target, bothValidators()));

    assertTrue(answered.isEmpty(), "an unchanged archive was reported as a download");
    assertArrayEquals(body, Files.readAllBytes(target), "the cached archive was written over");
  }

  /// A source that has something new to say answers with it, and what it answers with is the
  /// archive from then on.
  @Test
  void anArchiveTheSourceServesAgainReplacesTheOneOnDisk() throws Exception {
    var replaced =
        PipelineFixture.archive("fixture-aa1/fixture.control", "default_version = '2'", 0L);
    forge.answerWithEtag(ETAG, replaced);
    Files.createDirectories(target.getParent());
    Files.write(target, body);

    var answered =
        DownloadHarness.await(
            forge
                .sourceArchive(DOWNLOAD_TIMEOUT)
                .refresh(forge.url("/archive"), target, new Validators("\"stale\"", null)));

    assertArrayEquals(replaced, Files.readAllBytes(target));
    assertEquals(DigestUtils.sha256sum(ByteBuffer.wrap(replaced)), answered.orElseThrow().sha256());
    assertEquals(ETAG, answered.orElseThrow().etag());
  }

  /// A refusal is still a refusal when the request was conditional, and the archive the cache
  /// already holds is not something a 404 says anything about.
  @Test
  void theCachedArchiveOutlivesRefreshesThatFail() throws Exception {
    forge.answerWithStatus(NOT_FOUND, "no such repository");
    Files.createDirectories(target.getParent());
    Files.write(target, body);

    DownloadHarness.awaitFailure(
        forge
            .sourceArchive(DOWNLOAD_TIMEOUT)
            .refresh(forge.url("/archive"), target, bothValidators()));

    assertArrayEquals(body, Files.readAllBytes(target));
    assertFalse(
        Files.exists(SourceArchive.partialPath(target)),
        "the refusal outlived the refresh that failed");
  }
}
