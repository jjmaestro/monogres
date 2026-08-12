package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.fetch.SourceArchive.Validators;
import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.TagLister;
import dev.monogres.monobot.scan.Scan;
import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.TestProfile;
import io.vertx.core.Future;
import jakarta.inject.Inject;
import java.nio.file.Path;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// Asking the source about an archive the cache could already answer for.
///
/// A tag that moves is a tag that lied, so this is off by default; when it is on, the question is
/// asked with the validators the cache recorded, and a source that still serves the same bytes
/// answers 304. That is the difference between confirming a hundred archives and downloading them.
@QuarkusTest
@TestProfile(RefreshCacheTestProfile.class)
class FetchCacheRefreshTest {
  private static final String EXTENSION_DIR = "extensions/fixture";
  private static final String VERSION = "0.1.0";
  private static final String ETAG = "\"5f2e1a\"";
  private static final String LAST_MODIFIED = "Wed, 21 Oct 2026 07:28:00 GMT";

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

  @Inject ObjectMapper objectMapper;

  private final List<Validators> asked = new CopyOnWriteArrayList<>();

  private byte[] archiveBytes() throws Exception {
    return PipelineFixture.controlArchive(
        "fixture", "fixture-" + VERSION, PipelineFixture.control(VERSION, "fixture"), 0L);
  }

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    PipelineFixture.writeConfig(EXTENSION_DIR, CONFIG);
    asked.clear();

    when(tagLister.getTags(any())).thenReturn(new GitTag[] {});

    // The first run has nothing to condition on, so it is a plain download, and the validators it
    // reports are what the second run has to hand back.
    when(sourceArchive.download(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              var served = PipelineFixture.served(target, archiveBytes()).result();

              return Future.succeededFuture(
                  new SourceArchive.Download(served.sha256(), served.size(), ETAG, LAST_MODIFIED));
            });
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  private String catalogued() throws Exception {
    return objectMapper
        .readTree(PipelineFixture.repoJson(EXTENSION_DIR).toFile())
        .path("versions")
        .path(VERSION)
        .path("sha256")
        .asText();
  }

  @Test
  void theSecondRunAsksAgainWithWhatTheFirstRunWasGiven() throws Exception {
    when(sourceArchive.refresh(any(), any(), any()))
        .thenAnswer(
            invocation -> {
              asked.add(invocation.getArgument(2));

              return Future.succeededFuture(Optional.empty());
            });

    run();
    run();

    assertEquals(List.of(new Validators(ETAG, LAST_MODIFIED)), asked);
  }

  /// A source that answers 304 says the file already there is the current one, so the digest the
  /// catalog records has to be the one the cache already held.
  @Test
  void anArchiveTheSourceCallsUnchangedKeepsItsDigest() throws Exception {
    when(sourceArchive.refresh(any(), any(), any()))
        .thenReturn(Future.succeededFuture(Optional.empty()));

    run();
    var first = catalogued();
    run();

    assertEquals(first, catalogued());
  }

  @Test
  void anArchiveTheSourceServesAgainIsCataloguedAsWhatItNowIs() throws Exception {
    when(sourceArchive.refresh(any(), any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              var replaced =
                  PipelineFixture.served(
                          target,
                          PipelineFixture.controlArchive(
                              "fixture",
                              "fixture-" + VERSION,
                              PipelineFixture.control(VERSION, "rebuilt"),
                              0L))
                      .result();

              return Future.succeededFuture(Optional.of(replaced));
            });

    run();
    var first = catalogued();
    run();

    assertNotEquals(first, catalogued(), "the replaced archive was catalogued as the old one");
  }
}
