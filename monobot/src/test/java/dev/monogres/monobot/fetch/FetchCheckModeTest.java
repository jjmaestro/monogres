package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
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
import jakarta.inject.Inject;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// The gate the committed catalog is run through: everything `generate` does except the write, and
/// a non-zero exit when the two disagree.
///
/// What makes it a gate rather than a second opinion is that the document it compares is built by
/// the same code and printed by the same printer as the one `generate` writes. A checker with its
/// own idea of the layout would report the difference between two programs.
@QuarkusTest
@TestProfile(CheckModeTestProfile.class)
class FetchCheckModeTest {
  private static final String EXTENSION_DIR = "extensions/fixture";
  private static final String VERSION = "0.1.0";

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

  /// What a run over this config produces, which is what a committed catalog holds. The digest is
  /// of the fixture archive, so it is whatever the fixture generates rather than a value to look
  /// up: it is filled in below.
  private static final String REPO_JSON =
      """
      {
        "version": 1,
        "sources": {
          "gh": {
            "tag": "v{version}",
            "name": "fixture",
            "strip_prefix": "{name}-{version}",
            "url": "https://github.com/monogres/{name}/archive/refs/tags/{tag}.tar.gz"
          }
        },
        "versions": {
          "0.1.0": {
            "sha256": "%s"
          }
        },
        "metadata": {}
      }
      """;

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  @BeforeEach
  void setUp() throws Exception {
    PipelineFixture.resetTree();
    PipelineFixture.writeConfig(EXTENSION_DIR, CONFIG);

    when(tagLister.getTags(any())).thenReturn(new GitTag[] {});
    when(sourceArchive.download(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);

              return PipelineFixture.served(target, archiveBytes());
            });
  }

  /// Neither a control file nor a META.json, so one run produces exactly one document and what the
  /// check compares is `repo.json` and nothing else.
  private static byte[] archiveBytes() throws Exception {
    return PipelineFixture.archive("fixture-" + VERSION + "/README.md", "nothing here", 0L);
  }

  private void run() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);
  }

  /// The catalog as a run over these inputs produces it, put there by hand so that the check has
  /// something to agree with and nothing to have written itself.
  private void commitTheCatalogue() throws Exception {
    var digest = DigestUtils.sha256sum(ByteBuffer.wrap(archiveBytes()));

    PipelineFixture.writeRepoJson(EXTENSION_DIR, REPO_JSON.formatted(digest));
  }

  @Test
  void theTreeThatAlreadyHoldsTheAnswerPasses() throws Exception {
    commitTheCatalogue();

    run();
  }

  @Test
  void repoJsonThatDiffersFailsAndIsLeftAlone() throws Exception {
    commitTheCatalogue();
    var target = PipelineFixture.repoJson(EXTENSION_DIR);
    var committed = Files.readString(target).replace("\"version\": 1", "\"version\": 1  ");
    Files.writeString(target, committed);

    var failure = assertThrows(ExecutionException.class, this::run);

    assertTrue(
        failure.getMessage().contains("differ from what is committed"),
        "the failure does not say what happened: " + failure.getMessage());
    assertEquals(committed, Files.readString(target), "check wrote over what it was checking");
  }

  /// A catalog with nothing in it is as much a difference as a wrong one, and the mode that finds
  /// it is not the mode that fixes it.
  @Test
  void anEntryThatIsNotCommittedAtAllFailsWithoutWritingIt() throws Exception {
    assertThrows(ExecutionException.class, this::run);

    assertFalse(
        Files.exists(PipelineFixture.repoJson(EXTENSION_DIR)),
        "check wrote the repo.json it was only supposed to ask about");
  }

  /// The archives still have to arrive and they still go into the cache: checking is the same run
  /// as generating, minus the write. So a check leaves the next generate with nothing to download.
  @Test
  void theArchivesStillReachTheCache() throws Exception {
    commitTheCatalogue();

    run();

    var cached = PipelineFixture.cached(EXTENSION_DIR, VERSION);
    assertTrue(Files.exists(cached.resolve("fetch.json")), "nothing was recorded in the cache");
    assertTrue(Files.exists(cached.resolve("v0.1.0.tar.gz")), "the archive was not kept");
  }
}
