package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.TagLister;
import dev.monogres.monobot.scan.Scan;
import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.TestProfile;
import jakarta.inject.Inject;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// Corruption that leaves the length alone, which is the one thing a size check cannot see and the
/// reason `verifyCache=digest` exists. A cached archive is durable raw data and outlives many runs,
/// so what happens to it between them is not monobot's to predict.
@QuarkusTest
@TestProfile(VerifyDigestTestProfile.class)
class FetchCacheVerifyTest {
  private static final String EXTENSION_DIR = "extensions/fixture";
  private static final String VERSION = "0.1.0";
  private static final String ARCHIVE = "v0.1.0.tar.gz";

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
        "versions": { "pin": ["0.1.0"] }
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

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

              return PipelineFixture.served(
                  target,
                  PipelineFixture.controlArchive(
                      "fixture",
                      "fixture-" + VERSION,
                      PipelineFixture.control(VERSION, "fixture"),
                      0L));
            });
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  @Test
  void anArchiveWhoseBytesChangedUnderTheSameLengthIsFetchedAgain() throws Exception {
    run();
    downloads.set(0);

    var archive = PipelineFixture.cached(EXTENSION_DIR, VERSION).resolve(ARCHIVE);
    var corrupted = Files.readAllBytes(archive);
    corrupted[corrupted.length / 2] ^= (byte) 0xff;
    Files.write(archive, corrupted);

    run();

    assertEquals(1, downloads.get(), "the corrupted archive was reused");
  }

  @Test
  void anArchiveThatStillDigestsToWhatWasRecordedIsReused() throws Exception {
    run();
    downloads.set(0);

    run();

    assertEquals(0, downloads.get(), "an archive that was checked and agreed was fetched again");
  }
}
