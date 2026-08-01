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
import dev.monogres.monobot.git.ForgeType;
import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.Repo;
import dev.monogres.monobot.git.TagLister;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Optional;
import org.eclipse.jgit.api.errors.GitAPIException;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class Fetch {
  private static final Logger LOG = Logger.getLogger(Fetch.class);

  private static final String DIR_ARCHIVES = "archives";
  private static final String DIR_BUILD = "build";
  private static final String FILENAME_REPO_JSON = "repo.json";

  @ConfigProperty(name = "workdir")
  String workdir;

  @ConfigProperty(name = "configDir")
  String configDir;

  @ConfigProperty(name = "monogresRepo")
  String monogresRepo;

  @Inject Vertx vertx;

  @Inject SourceArchive sourceArchive;

  @Inject ObjectMapper objectMapper;

  @Inject ArchiveMetadataExtractor archiveMetadataExtractor;

  @Inject TagLister tagLister;

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

  private Future<Void> fetchVersionsByTag(
      MonobotConfig monobotConfig, Repo repo, Versions versions, Metadata metadata) {
    GitTag[] tags;
    try {
      tags = tagLister.getTags(monobotConfig.repoUrl());
    } catch (GitAPIException e) {
      LOG.warnv(
          e,
          "[{0}]: Error while fetching tags from repo {1}",
          monobotConfig.name(),
          monobotConfig.repoUrl());
      return Future.succeededFuture();
    }

    var versionSpec = monobotConfig.versionSpec();
    var downloadFutures = new ArrayList<Future<VersionDownloadResult>>();
    var candidates = new ArrayList<Version>(versions.keySet());
    var versionsFound = 0;

    for (var tag : tags) {
      var versionFound = Version.find(versionSpec.rewrite(tag.name()));

      if (versionFound.isEmpty()) {
        continue;
      }

      versionsFound++;
      var version = versionFound.get();
      if (!versionSpec.satisfiedBy(version)) {
        LOG.infov(
            "[{0}]: Tag {1} ({2}) is outside {3}",
            monobotConfig.name(), tag.name(), version, versionSpec.satisfy());
        continue;
      }

      candidates.add(version);
      if (versions.containsKey(version)) {
        continue;
      }

      var archivePath =
          Path.of(workdir, DIR_ARCHIVES, monobotConfig.name(), tag.commit().name() + ".tar.gz");

      var downloadFuture =
          sourceArchive
              .sha256UrlFile(repo.getArchiveUrl(tag), archivePath)
              .map(
                  sha256 ->
                      new VersionDownloadResult(
                          version, tag, sha256, archivePath, repo.getArchiveStripPrefix(tag)));

      downloadFutures.add(downloadFuture);
    }

    if (versionsFound == 0) {
      LOG.warnv(
          "[{0}]: None of the {1} tags of {2} names a version",
          monobotConfig.name(), tags.length, monobotConfig.repoUrl());
    }

    if (downloadFutures.isEmpty()) {
      return Future.succeededFuture();
    }

    var newest = candidates.stream().max(Comparator.naturalOrder());

    return Future.all(downloadFutures)
        .compose(
            compositeFuture ->
                vertx.executeBlocking(
                    () -> {
                      for (var i = 0; i < compositeFuture.size(); i++) {
                        var result = (VersionDownloadResult) compositeFuture.resultAt(i);
                        // One read per archive, answering both the cutoff and the metadata.
                        // Gunzipping and walking a whole tarball is the most expensive thing this
                        // program does per version, and this block is ordered, so every one of
                        // them serialises behind the last.
                        var contents =
                            archiveMetadataExtractor.read(
                                monobotConfig.name(), result.archivePath());
                        if (!isRecentEnough(
                            monobotConfig, result, newest, contents.lastModified())) {
                          continue;
                        }
                        versions.put(
                            result.version(),
                            new VersionContext(
                                result.tag().name(),
                                result.tag().commit(),
                                result.sha256(),
                                result.stripPrefix()));
                        archiveMetadataExtractor.addContents(result.version(), contents, metadata);
                      }
                      return null;
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
            v ->
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
                        return null;
                      }

                      if (metadata.isEmpty()) {
                        LOG.warnv(
                            "[{0}]: no version came with metadata, so no repo.json is written."
                                + " No archive carried a META.json or a {0}.control, and `name` is"
                                + " what names that file, so a name that is not the control file"
                                + " stem of the extension looks exactly like this",
                            monobotConfig.name());
                        return null;
                      }

                      var sources = new Sources();
                      var sourcesContext =
                          new SourceContext(
                              repo.getArchiveUrlTemplate(), repo.getArchiveUrlExtension());
                      sources.put(repo.getForgeType().getDomain(), sourcesContext);

                      var repoConfig = new RepoConfig(sources, versions, metadata);
                      writeConfigFile(outputDir, FILENAME_REPO_JSON, repoConfig);
                      return null;
                    }));
  }

  private void writeConfigFile(Path configDir, String filename, Object object) {
    try {
      Files.createDirectories(configDir);
      objectMapper.writeValue(configDir.resolve(filename).toFile(), object);
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
