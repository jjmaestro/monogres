package dev.monogres.monobot.fetch;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.TreeSet;
import org.apache.commons.compress.archivers.tar.TarArchiveEntry;
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream;
import org.apache.commons.compress.archivers.tar.TarArchiveOutputStream;
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream;
import org.apache.commons.compress.compressors.gzip.GzipCompressorOutputStream;
import org.apache.commons.compress.compressors.gzip.GzipParameters;
import org.eclipse.jgit.lib.ObjectId;

/// The tree and the archives every pipeline test runs against. Archives are generated rather than
/// committed, so a digest asserted anywhere is the digest of bytes this fixture actually produced.
/// That needs the bytes to be stable: tar records a modification time, owner and mode per entry
/// and gzip records one in its header, so every one of them is pinned here.
final class PipelineFixture {
  static final Path ROOT = PipelineTestProfile.ROOT;
  static final Path CONFIG_DIR = PipelineTestProfile.CONFIG_DIR;
  static final Path WORKDIR = PipelineTestProfile.WORKDIR;
  static final Path MONOGRES_REPO = PipelineTestProfile.MONOGRES_REPO;

  private static final int TAR_MODE_RW_R_R = 420;

  private static final String CONTROL_TEMPLATE =
      """
      default_version = '%s'
      comment = '%s'
      relocatable = false
      """;

  private PipelineFixture() {}

  /// A commit id from a short hex seed, so a test can name its commits and still hand JGit the 40
  /// characters it insists on.
  static String commitSha(String seed) {
    return (seed + "0".repeat(40)).substring(0, 40);
  }

  static ObjectId objectId(String seed) {
    return ObjectId.fromString(commitSha(seed));
  }

  static byte[] archive(String entryName, String content, long modifiedMillis) throws IOException {
    var body = content.getBytes(StandardCharsets.UTF_8);
    var raw = new ByteArrayOutputStream();

    var gzipParameters = new GzipParameters();
    gzipParameters.setModificationTime(0L);

    try (var gz = new GzipCompressorOutputStream(raw, gzipParameters);
        var tar = new TarArchiveOutputStream(gz)) {
      var entry = new TarArchiveEntry(entryName);
      entry.setSize(body.length);
      entry.setModTime(modifiedMillis);
      entry.setIds(0, 0);
      entry.setNames("", "");
      entry.setMode(TAR_MODE_RW_R_R);
      tar.putArchiveEntry(entry);
      tar.write(body);
      tar.closeArchiveEntry();
    }

    return raw.toByteArray();
  }

  /// The layout a forge serves: one top-level directory named for the strip prefix, holding the
  /// extension's control file, which is the only thing metadata extraction looks for.
  static byte[] controlArchive(
      String extension, String stripPrefix, String control, long modifiedMillis)
      throws IOException {
    return archive(stripPrefix + "/" + extension + ".control", control, modifiedMillis);
  }

  /// The single top-level directory of an archive on disk, read back out of it. This is what
  /// `strip_prefix` is a prediction of, and reading it is the only way to compare the prediction
  /// against anything but itself.
  static String rootDirectoryOf(Path archive) throws IOException {
    try (var raw = new BufferedInputStream(Files.newInputStream(archive));
        var gzipIn = new GzipCompressorInputStream(raw);
        var tarIn = new TarArchiveInputStream(gzipIn)) {
      var roots = new TreeSet<String>();
      TarArchiveEntry entry;

      while ((entry = tarIn.getNextEntry()) != null) {
        roots.add(entry.getName().split("/")[0]);
      }
      if (roots.size() != 1) {
        throw new IllegalStateException(archive + " has " + roots.size() + " top-level entries");
      }

      return roots.first();
    }
  }

  static String control(String defaultVersion, String comment) {
    return CONTROL_TEMPLATE.formatted(defaultVersion, comment);
  }

  static void resetTree() throws IOException {
    deleteRecursively(ROOT);
    Files.createDirectories(WORKDIR);
    Files.createDirectories(MONOGRES_REPO);
  }

  static void writeConfig(String relativeDir, String json) throws IOException {
    var dir = CONFIG_DIR.resolve(relativeDir);
    Files.createDirectories(dir);
    Files.writeString(dir.resolve("monobot.json"), json);
  }

  /// Seeds the output of a previous run, which the next one reads back and merges into.
  static void writeRepoJson(String relativeDir, String json) throws IOException {
    var target = repoJson(relativeDir);
    Files.createDirectories(target.getParent());
    Files.writeString(target, json);
  }

  static Path repoJson(String relativeDir) {
    return MONOGRES_REPO.resolve("build").resolve(relativeDir).resolve("repo.json");
  }

  static void deleteRecursively(Path path) throws IOException {
    if (!Files.exists(path)) {
      return;
    }
    try (var walk = Files.walk(path)) {
      for (var p : walk.sorted(Comparator.reverseOrder()).toList()) {
        Files.delete(p);
      }
    }
  }
}
