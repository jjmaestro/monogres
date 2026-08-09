package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.TagLister;
import dev.monogres.monobot.scan.Scan;
import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.TestProfile;
import io.vertx.core.Future;
import jakarta.inject.Inject;
import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.ThrowingSupplier;

/// Where the tag listing runs. It is a blocking network round trip and there is one per extension,
/// so whatever thread it runs on is a thread held for the sum of every forge's latency.
///
/// [dev.monogres.monobot.main.Main] arms the whole-run bound only once `scan.run()` has returned,
/// which makes everything `run` does before returning work that no bound covers.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchTagListingTest {
  private static final String CONFIG =
      """
      {
        "name": "fixture",
        "url": "https://github.com/monogres/fixture"
      }
      """;

  private static final Duration GIVE_UP = Duration.ofSeconds(10);

  @InjectMock TagLister tagLister;

  @Inject Scan scan;

  private final CountDownLatch listing = new CountDownLatch(1);

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    PipelineFixture.writeConfig("extensions/fixture", CONFIG);
    when(tagLister.getTags(any()))
        .thenAnswer(
            invocation -> {
              listing.await();
              return new GitTag[0];
            });
  }

  /// Whatever is still blocked when the test ends has to be let go, or it holds a thread for the
  /// rest of the suite.
  @AfterEach
  void tearDown() {
    listing.countDown();
  }

  /// Preemptively, because the shape this guards is a call that does not return: measuring
  /// afterwards would mean never measuring. `GIVE_UP` costs seconds, not the target's own limit.
  @Test
  void theScanReturnsWithoutWaitingForTheTagListing() throws Exception {
    var scanFuture =
        assertTimeoutPreemptively(GIVE_UP, (ThrowingSupplier<Future<Void>>) () -> scan.run());

    assertFalse(scanFuture.isComplete(), "the scan settled before its tag listing answered");

    listing.countDown();
    scanFuture.toCompletionStage().toCompletableFuture().get(GIVE_UP.toSeconds(), TimeUnit.SECONDS);
  }
}
