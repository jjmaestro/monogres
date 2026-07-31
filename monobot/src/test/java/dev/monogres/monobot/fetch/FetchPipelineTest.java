package dev.monogres.monobot.fetch;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
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
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.concurrent.TimeUnit;
import org.apache.commons.compress.archivers.tar.TarArchiveEntry;
import org.apache.commons.compress.archivers.tar.TarArchiveOutputStream;
import org.apache.commons.compress.compressors.gzip.GzipCompressorOutputStream;
import org.apache.commons.compress.compressors.gzip.GzipParameters;
import org.eclipse.jgit.lib.ObjectId;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/// Drives the whole pipeline, Scan through Fetch to the written repo.json, with the two network
/// calls replaced: [TagLister] returns fixed tags and [SourceArchive] writes a generated archive
/// instead of downloading one. Everything between them is the real code, including the tag
/// normalization and the .control extraction.
///
/// The archive is built here rather than committed as a binary, and its sha256 is the digest of
/// the bytes actually written, so the value in the golden is derived rather than asserted against
/// itself. That requires the archive to be byte-stable: tar records a modification time, owner and
/// mode per entry, and gzip records one in its header, so all of them are pinned below.
@QuarkusTest
@TestProfile(PipelineTestProfile.class)
class FetchPipelineTest {
  private static final String GOLDEN = "golden/pipeline-repo.json";
  private static final String CONTROL =
      """
      default_version = '1.2.3'
      comment = 'a fixture extension'
      relocatable = false
      """;
  private static final String COMMIT = "8cf409d1b669e0e3e22fa79bb54027a4b555e822";

  @InjectMock TagLister tagLister;

  @InjectMock SourceArchive sourceArchive;

  @Inject Scan scan;

  private static byte[] archive() throws IOException {
    var body = CONTROL.getBytes(StandardCharsets.UTF_8);
    var raw = new ByteArrayOutputStream();

    var gzipParameters = new GzipParameters();
    gzipParameters.setModificationTime(0L);

    try (var gz = new GzipCompressorOutputStream(raw, gzipParameters);
        var tar = new TarArchiveOutputStream(gz)) {
      var entry = new TarArchiveEntry("fixture-" + COMMIT + "/fixture.control");
      entry.setSize(body.length);
      entry.setModTime(0L);
      entry.setIds(0, 0);
      entry.setNames("", "");
      entry.setMode(420);
      tar.putArchiveEntry(entry);
      tar.write(body);
      tar.closeArchiveEntry();
    }

    return raw.toByteArray();
  }

  private static void writeConfig() throws IOException {
    var dir = PipelineTestProfile.CONFIG_DIR.resolve("extensions").resolve("fixture");
    Files.createDirectories(dir);
    Files.writeString(
        dir.resolve("monobot.json"),
        """
        {
          "name": "fixture",
          "url": "https://github.com/monogres/fixture"
        }
        """);
  }

  private static void deleteRecursively(Path path) throws IOException {
    if (!Files.exists(path)) {
      return;
    }
    try (var walk = Files.walk(path)) {
      for (var p : walk.sorted(Comparator.reverseOrder()).toList()) {
        Files.delete(p);
      }
    }
  }

  private static String golden() throws IOException {
    try (InputStream in = FetchPipelineTest.class.getClassLoader().getResourceAsStream(GOLDEN)) {
      assertNotNull(in, GOLDEN + " is missing from the test resources");
      return new String(in.readAllBytes(), StandardCharsets.UTF_8).stripTrailing();
    }
  }

  @BeforeEach
  void setUp() throws Exception {
    deleteRecursively(PipelineTestProfile.ROOT);
    Files.createDirectories(PipelineTestProfile.WORKDIR);
    Files.createDirectories(PipelineTestProfile.MONOGRES_REPO);
    writeConfig();

    when(tagLister.getTags(any()))
        .thenReturn(new GitTag[] {new GitTag("v1.2.3", ObjectId.fromString(COMMIT))});

    // Stands in for the download: writes the generated archive where the caller asked for it and
    // returns the digest of those bytes, which is what the real implementation does.
    when(sourceArchive.sha256UrlFile(any(), any()))
        .thenAnswer(
            invocation -> {
              Path target = invocation.getArgument(1);
              var bytes = archive();
              Files.createDirectories(target.getParent());
              Files.write(target, bytes);
              return Future.succeededFuture(DigestUtils.sha256sum(ByteBuffer.wrap(bytes)));
            });
  }

  @Test
  void writesTheGoldenRepoJson() throws Exception {
    scan.run().toCompletionStage().toCompletableFuture().get(60, TimeUnit.SECONDS);

    var written =
        PipelineTestProfile.MONOGRES_REPO
            .resolve("build")
            .resolve("extensions")
            .resolve("fixture")
            .resolve("repo.json");
    assertTrue(Files.exists(written), "the pipeline wrote no repo.json at " + written);
    assertEquals(golden(), Files.readString(written).stripTrailing());
  }
}
