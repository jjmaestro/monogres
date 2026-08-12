package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

import dev.monogres.monobot.digest.DigestUtils;
import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.TagLister;
import dev.monogres.monobot.scan.Scan;
import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.TestProfile;
import io.vertx.core.Future;
import jakarta.inject.Inject;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// A config that carries no metadata of its own, over archives carrying neither a control file nor
/// a META.json. Nothing about that shape is exotic: it is the bare name-and-url example, against a
/// repository whose control file is not named after the config.
///
/// No metadata means no repo.json, and no repo.json means the next run starts with an empty
/// catalog, which is what turns this into a run that downloads every tag of the extension, every
/// time, forever, against an anonymous client with no retry budget.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchSpoolReuseTest {
  private static final String EXTENSION_DIR = "extensions/fixture";

  private static final String CONFIG =
      """
      {
        "name": "fixture",
        "url": "https://github.com/monogres/fixture",
        "versions": { "replace": [["^v(.*)$", "$1"]] }
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

    when(tagLister.getTags(any()))
        .thenReturn(
            new GitTag[] {
              new GitTag("v0.2.0", PipelineFixture.objectId("aa2")),
              new GitTag("v0.1.0", PipelineFixture.objectId("aa1"))
            });

    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              downloads.incrementAndGet();
              Path target = invocation.getArgument(1);
              // Neither a control file nor a META.json, so the archive answers for no metadata.
              var bytes = PipelineFixture.archive("fixture-aa1/README.md", "nothing here", 0L);
              Files.createDirectories(target.getParent());
              Files.write(target, bytes);
              return Future.succeededFuture(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
            });

    // The archive already on disk is digested rather than fetched, so the stub has to answer for
    // that too: it is the same class, one method further in.
    when(sourceArchive.digest(any()))
        .thenAnswer(
            invocation ->
                Future.succeededFuture(
                    DigestUtils.sha256sum(
                        ByteBuffer.wrap(Files.readAllBytes(invocation.<Path>getArgument(0))))));
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  @Test
  void secondRunOverTheSameInputsAsksTheForgeForNothing() throws Exception {
    run();

    assertEquals(2, downloads.get(), "the first run did not fetch both tags");
    assertFalse(
        Files.exists(PipelineFixture.repoJson(EXTENSION_DIR)),
        "an extension no version carried metadata for is not catalogued");

    downloads.set(0);
    run();

    assertEquals(0, downloads.get(), "the second run fetched archives it already had");
  }

  /// The spool is what records that a commit has been fetched, so it has to hold both of them.
  @Test
  void everyFetchedArchiveStaysInTheSpool() throws Exception {
    run();

    var spool = PipelineFixture.WORKDIR.resolve("archives").resolve("fixture");
    try (var entries = Files.list(spool)) {
      assertEquals(
          List.of(
              PipelineFixture.commitSha("aa1") + ".tar.gz",
              PipelineFixture.commitSha("aa2") + ".tar.gz"),
          entries.map(path -> path.getFileName().toString()).sorted().toList());
    }
    assertTrue(Files.isDirectory(spool));
  }
}
