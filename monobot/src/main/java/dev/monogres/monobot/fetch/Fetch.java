package dev.monogres.monobot.fetch;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.Metadata;
import dev.monogres.monobot.config.input.MonobotConfig;
import dev.monogres.monobot.config.input.MonobotConfigFile;
import dev.monogres.monobot.config.output.RepoConfig;
import dev.monogres.monobot.config.output.SourceContext;
import dev.monogres.monobot.config.output.Sources;
import dev.monogres.monobot.config.output.Version;
import dev.monogres.monobot.config.output.VersionContext;
import dev.monogres.monobot.config.output.Versions;
import dev.monogres.monobot.fetch.ArchiveMetadataExtractor.ArchiveContents;
import dev.monogres.monobot.git.ForgeType;
import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.Repo;
import dev.monogres.monobot.git.TagLister;
import dev.monogres.monobot.json.CatalogPrinter;
import dev.monogres.monobot.report.RunSummary;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class Fetch {
  private static final Logger LOG = Logger.getLogger(Fetch.class);

  private static final String DIR_ARCHIVES = "archives";
  private static final String DIR_BUILD = "build";
  private static final String FILENAME_REPO_JSON = "repo.json";

  private static final int NOTHING_REFUSED = 0;

  @ConfigProperty(name = "workdir")
  String workdir;

  @ConfigProperty(name = "configDir")
  String configDir;

  @ConfigProperty(name = "monogresRepo")
  String monogresRepo;

  @Inject Vertx vertx;

  @Inject SourceArchive sourceArchive;

  @Inject DownloadLimiter downloadLimiter;

  @Inject ObjectMapper objectMapper;

  @Inject ArchiveMetadataExtractor archiveMetadataExtractor;

  @Inject TagLister tagLister;

  @Inject RunSummary summary;

  private record VersionDownloadResult(
      Version version, GitTag tag, String sha256, Path archivePath, String stripPrefix) {}

  /// Whether an archive is recent enough to catalogue, which requires downloading the archive.
  ///
  /// `keepNewest` spares one version, and which one is named rather than left to the order the
  /// downloads happen to complete in: the newest of everything this run knows about, whether it
  /// came from the tag listing or from the catalog being merged into.
  private boolean isRecentEnough(
      MonobotConfig monobotConfig,
      VersionDownloadResult result,
      Optional<Version> newest,
      Instant lastModified) {
    var versionSpec = monobotConfig.versionSpec();
    var cutoff = versionSpec.cutoff();

    if (cutoff.isEmpty()
        || (versionSpec.keepNewest() && newest.filter(result.version()::equals).isPresent())) {
      return true;
    }

    var isRecentEnough = !lastModified.isBefore(cutoff.get());

    if (!isRecentEnough) {
      LOG.infov(
          "[{0}]: Tag {1} ({2}) was last modified {3}, before the cutoff {4}",
          monobotConfig.name(), result.tag().name(), result.version(), lastModified, cutoff.get());
    }

    return isRecentEnough;
  }

  /// What the catalog records about one version, all of it read from the archive that version was
  /// tagged at. The archive is read first so that a version it cannot answer for is left out
  /// altogether rather than recorded with no metadata against it.
  private void catalogue(
      VersionDownloadResult result,
      ArchiveContents contents,
      Versions versions,
      Metadata metadata) {
    archiveMetadataExtractor.addContents(result.version(), contents, metadata);
    versions.put(
        result.version(),
        new VersionContext(
            result.tag().name(), result.tag().commit(), result.sha256(), result.stripPrefix()));
  }

  /// The listing is a blocking network round trip, so it runs on a worker rather than on the
  /// thread that asked for it. Run inline, every extension's listing completes before
  /// [dev.monogres.monobot.main.Main] arms `runTimeout`, which leaves the phase with the most
  /// network in it outside the only bound on the process. Unordered, so one slow forge holds up
  /// only itself; how many run at once is the size of the Vert.x worker pool.
  ///
  /// A listing that fails leaves the run carrying on with that extension untouched, since its
  /// stored `repo.json` is still the best answer available for it.
  private Future<Integer> fetchVersionsByTag(
      MonobotConfig monobotConfig, Repo repo, Versions versions, Metadata metadata) {
    return vertx
        .executeBlocking(() -> tagLister.getTags(monobotConfig.repoUrl()), false)
        .transform(
            listed -> {
              if (listed.failed()) {
                summary.extensionFailed();
                LOG.warnv(
                    listed.cause(),
                    "[{0}]: Error while fetching tags from repo {1}",
                    monobotConfig.name(),
                    monobotConfig.repoUrl());
                return Future.succeededFuture(NOTHING_REFUSED);
              }

              return downloadVersionsByTag(
                  monobotConfig, repo, versions, metadata, listed.result());
            });
  }

  /// The digest of this commit's archive, fetching it only if the spool does not already hold it.
  ///
  /// The spool is addressed by commit, so a file at that path is that commit's archive and nothing
  /// else, which makes it the record of what has already been fetched. Without that record the
  /// only one is `repo.json`, and an extension no version carried metadata for writes none, so
  /// every run starts with an empty catalog and asks the forge for every tag again. Forever, at
  /// exit 0, against a client with no credentials and no retry budget.
  private Future<String> archiveDigest(Repo repo, GitTag tag, Path archivePath) {
    if (Files.exists(archivePath)) {
      return sourceArchive.digest(archivePath);
    }

    return downloadLimiter.withPermit(
        () -> sourceArchive.sha256UrlFile(repo.getArchiveUrl(tag), archivePath));
  }

  /// How many of this extension's archives the forge would not serve. Each download recovers into
  /// an empty result rather than failing, because one archive answers for one version: a composite
  /// that fails on the first refusal discards the versions that downloaded beside it, and does it
  /// while they are still in flight.
  private Future<Integer> downloadVersionsByTag(
      MonobotConfig monobotConfig, Repo repo, Versions versions, Metadata metadata, GitTag[] tags) {
    var versionSpec = monobotConfig.versionSpec();
    var downloadFutures = new ArrayList<Future<Optional<VersionDownloadResult>>>();
    var refused = new AtomicInteger();
    var candidates = new ArrayList<Version>(versions.keySet());
    var versionsFound = 0;

    for (var tag : tags) {
      var versionFound = Version.find(versionSpec.rewrite(tag.name()));

      if (versionFound.isEmpty()) {
        summary.versionSkipped(RunSummary.Skipped.NO_VERSION_IN_TAG);
        continue;
      }

      versionsFound++;
      var version = versionFound.get();
      if (!versionSpec.satisfiedBy(version)) {
        LOG.infov(
            "[{0}]: Tag {1} ({2}) is outside {3}",
            monobotConfig.name(), tag.name(), version, versionSpec.satisfy());
        summary.versionSkipped(RunSummary.Skipped.OUTSIDE_SATISFY);
        continue;
      }

      candidates.add(version);
      if (versions.containsKey(version)) {
        summary.versionSkipped(RunSummary.Skipped.ALREADY_STORED);
        continue;
      }

      var archivePath =
          Path.of(workdir, DIR_ARCHIVES, monobotConfig.name(), tag.commit().name() + ".tar.gz");

      var downloadFuture =
          archiveDigest(repo, tag, archivePath)
              .map(
                  sha256 -> {
                    // Logged here rather than beside the request, which knows the URL and not the
                    // extension it belongs to, so attributing a download meant reversing the URL.
                    LOG.infov(
                        "[{0}]: Tag {1} ({2}) is at {3}",
                        monobotConfig.name(), tag.name(), version, archivePath);

                    return Optional.of(
                        new VersionDownloadResult(
                            version, tag, sha256, archivePath, repo.getArchiveStripPrefix(tag)));
                  })
              .recover(
                  err -> {
                    refused.incrementAndGet();
                    summary.versionSkipped(RunSummary.Skipped.REFUSED_DOWNLOAD);
                    LOG.errorv(
                        err,
                        "[{0}]: Tag {1} ({2}) could not be downloaded",
                        monobotConfig.name(),
                        tag.name(),
                        version);
                    return Future.succeededFuture(Optional.empty());
                  });

      downloadFutures.add(downloadFuture);
    }

    if (versionsFound == 0) {
      LOG.warnv(
          "[{0}]: None of the {1} tags of {2} names a version",
          monobotConfig.name(), tags.length, monobotConfig.repoUrl());
    }

    if (downloadFutures.isEmpty()) {
      return Future.succeededFuture(NOTHING_REFUSED);
    }

    var newest = candidates.stream().max(Comparator.naturalOrder());

    return Future.all(downloadFutures)
        .compose(
            compositeFuture ->
                vertx.executeBlocking(
                    () -> {
                      for (var i = 0; i < compositeFuture.size(); i++) {
                        Optional<VersionDownloadResult> downloaded = compositeFuture.resultAt(i);
                        if (downloaded.isEmpty()) {
                          continue;
                        }

                        var result = downloaded.get();
                        try {
                          // One read per archive, answering both the cutoff and the metadata.
                          // Gunzipping and walking a whole tarball is the most expensive thing this
                          // program does per version, and this block is ordered, so every one of
                          // them serialises behind the last.
                          var contents =
                              archiveMetadataExtractor.read(
                                  monobotConfig.name(), result.archivePath());
                          if (isRecentEnough(
                              monobotConfig, result, newest, contents.lastModified())) {
                            catalogue(result, contents, versions, metadata);
                            summary.versionAdded();
                          } else {
                            summary.versionSkipped(RunSummary.Skipped.BEFORE_CUTOFF);
                          }
                        } catch (RuntimeException e) {
                          summary.versionSkipped(RunSummary.Skipped.UNREADABLE_ARCHIVE);
                          LOG.errorv(
                              e,
                              "[{0}]: Tag {1} ({2}) has an archive that cannot be read",
                              monobotConfig.name(),
                              result.tag().name(),
                              result.version());
                        }
                      }
                      return refused.get();
                    }));
  }

  public Future<Void> fetch(MonobotConfigFile monobotConfigFile) {
    var monobotConfig = monobotConfigFile.monobotConfig();

    if (monobotConfig.disabled()) {
      LOG.infov(
          "[{0}]: {1} is disabled, so no tag of it is looked at",
          monobotConfig.name(), monobotConfig.repoUrl());
      return Future.succeededFuture();
    }

    var monobotConfigDir = monobotConfigFile.configFile().getParent();
    var relPath = Path.of(configDir).relativize(monobotConfigDir);
    var outputDir = Path.of(monogresRepo, DIR_BUILD).resolve(relPath);
    var storedRepo = readOrCreateRepoConfig(outputDir.resolve(FILENAME_REPO_JSON).toFile());
    var versions = storedRepo.getVersions() == null ? new Versions() : storedRepo.getVersions();
    var metadata = storedRepo.getMetadata() == null ? new Metadata() : storedRepo.getMetadata();
    if (!(monobotConfig.metadata() == null || monobotConfig.metadata().isEmpty())) {
      metadata.putAll(monobotConfig.metadata());
    }

    var repoUrl = monobotConfig.repoUrl();
    var repo = ForgeType.getRepo(repoUrl);

    return fetchVersionsByTag(monobotConfig, repo, versions, metadata)
        .compose(
            refused ->
                vertx.executeBlocking(
                    () -> {
                      // A catalog entry is a version and what that version is, so an extension
                      // that yielded one without the other is not catalogued at all. The
                      // alternative is a repo.json holding the formulas for building download
                      // URLs and no version to build one for.
                      if (versions.isEmpty()) {
                        LOG.warnv(
                            "[{0}]: no version was catalogued, so no repo.json is written",
                            monobotConfig.name());
                        return refused;
                      }

                      if (metadata.isEmpty()) {
                        LOG.warnv(
                            "[{0}]: no version came with metadata, so no repo.json is written."
                                + " No archive carried a META.json or a {0}.control, and `name` is"
                                + " what names that file, so a name that is not the control file"
                                + " stem of the extension looks exactly like this",
                            monobotConfig.name());
                        return refused;
                      }

                      var sources = new Sources();
                      var sourcesContext =
                          new SourceContext(
                              repo.getArchiveUrlTemplate(), repo.getArchiveUrlExtension());
                      sources.put(repo.getForgeType().getDomain(), sourcesContext);

                      var repoConfig = new RepoConfig(sources, versions, metadata);
                      writeConfigFile(outputDir, FILENAME_REPO_JSON, repoConfig);
                      summary.catalogWritten();
                      return refused;
                    }))
        // Reported after the catalogue has been written rather than instead of writing it: the
        // versions that did download are as good as they would have been on their own, and the
        // ones that did not are what the run has to answer for.
        .compose(
            refused -> {
              if (refused == NOTHING_REFUSED) {
                return Future.<Void>succeededFuture();
              }
              summary.extensionFailed();

              return Future.<Void>failedFuture(
                  new IOException(
                      "["
                          + monobotConfig.name()
                          + "]: "
                          + refused
                          + " archives could not be downloaded"));
            });
  }

  /// Written beside the destination and then moved onto it, so what is there is either the whole
  /// previous document or the whole new one. Written in place, a write that stops partway leaves a
  /// document that is neither, and that stops the extension for good: reading it back is how the
  /// next run starts, and deleting it by hand forfeits every sha256 it recorded.
  ///
  /// The temporary file is in the same directory because an atomic move is a rename, and a rename
  /// does not cross filesystems.
  void writeConfigFile(Path configDir, String filename, Object object) {
    try {
      Files.createDirectories(configDir);
      var written = Files.createTempFile(configDir, filename, ".tmp");
      try {
        Files.writeString(written, CatalogPrinter.print(objectMapper.valueToTree(object)));
        Files.move(written, configDir.resolve(filename), StandardCopyOption.ATOMIC_MOVE);
      } finally {
        Files.deleteIfExists(written);
      }
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }

  private RepoConfig readOrCreateRepoConfig(File repoConfigFile) {
    var repoConfig = readConfigFile(repoConfigFile, RepoConfig.class);

    return repoConfig == null ? new RepoConfig() : repoConfig;
  }

  private <T> T readConfigFile(File configFile, Class<T> clazz) {
    try {
      return objectMapper.readValue(configFile, clazz);
    } catch (FileNotFoundException e) {
      return null;
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }
}
