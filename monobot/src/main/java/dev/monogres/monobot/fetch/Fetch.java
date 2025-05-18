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
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.file.Path;
import org.eclipse.jgit.api.errors.GitAPIException;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class Fetch {
  private static final Logger LOG = Logger.getLogger(Fetch.class);

  private static final String DIR_ARCHIVES = "archives";
  private static final String FILENAME_REPO_JSON = "repo.json";

  @ConfigProperty(name = "workdir")
  String workdir;

  @Inject SourceArchive sourceArchive;

  @Inject ObjectMapper objectMapper;

  @Inject ArchiveMetadataExtractor archiveMetadataExtractor;

  private void fetchVersionsByTag(
      MonobotConfig monobotConfig, Repo repo, Versions versions, Metadata metadata) {
    try {
      for (var tag : GitTag.getTags(monobotConfig.repoUrl())) {
        var version = new Version(tag.name());
        if (versions.containsKey(version)) {
          continue;
        }

        var archivePath =
            Path.of(workdir, DIR_ARCHIVES, monobotConfig.name(), tag.commit().name() + ".tar.gz");
        var sha256 = sourceArchive.sha256UrlFile(repo.getArchiveUrl(tag), archivePath);
        versions.put(
            version,
            new VersionContext(tag.name(), tag.commit(), sha256, repo.getArchiveStripPrefix(tag)));

        archiveMetadataExtractor.addFromArchive(
            monobotConfig.name(), version, archivePath, metadata);
      }
    } catch (GitAPIException e) {
      LOG.warnv(
          "[{0}]: Error while fetching metadata from repo {1}",
          monobotConfig.name(), monobotConfig.repoUrl());
    }
  }

  public void fetch(MonobotConfigFile monobotConfigFile) {
    var monobotConfig = monobotConfigFile.monobotConfig();
    var configDir = monobotConfigFile.configFile().getParent();
    var storedRepo = readOrCreateRepoConfig(configDir.resolve(FILENAME_REPO_JSON).toFile());
    var versions = storedRepo.getVersions() == null ? new Versions() : storedRepo.getVersions();
    var metadata = storedRepo.getMetadata() == null ? new Metadata() : storedRepo.getMetadata();

    var repoUrl = monobotConfig.repoUrl();
    var repo = ForgeType.getByRepoUrl(repoUrl).newRepo(repoUrl);
    fetchVersionsByTag(monobotConfig, repo, versions, metadata);

    var sources = new Sources();
    var sourcesContext = new SourceContext(repo.getArchiveUrlRaw("{commit}"));
    sources.put(repo.getForgeType().getDomain(), sourcesContext);

    var repoConfig =
        new RepoConfig(
            sources, versions.isEmpty() ? null : versions, metadata.isEmpty() ? null : metadata);
    writeConfigFile(configDir, FILENAME_REPO_JSON, repoConfig);
  }

  private void writeConfigFile(Path configDir, String filename, Object object) {
    try {
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
