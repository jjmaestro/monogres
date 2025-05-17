package dev.monogres.monobot.fetch;

import com.fasterxml.jackson.databind.ObjectMapper;
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
import java.io.IOException;
import java.nio.file.Path;
import org.eclipse.jgit.api.errors.GitAPIException;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class Fetch {
  private static final Logger LOG = Logger.getLogger(Fetch.class);

  private static final String DIR_ARCHIVES = "archives";
  private static final String FILENAME_VERSIONS_JSON = "versions.json";
  private static final String FILENAME_REPO_JSON = "repo.json";

  @ConfigProperty(name = "workdir")
  String workdir;

  @Inject SourceArchive sourceArchive;

  @Inject ObjectMapper objectMapper;

  private void fetchAndPopulate(MonobotConfig monobotConfig, Repo repo, Versions storedVersions) {
    try {
      for (var tag : GitTag.getTags(monobotConfig.git().url())) {
        var version = new Version(tag.name());
        if (storedVersions.containsKey(version)) {
          continue;
        }

        var archivePath =
            Path.of(workdir, DIR_ARCHIVES, monobotConfig.name(), tag.commit().name() + ".tar.gz");
        var sha256 = sourceArchive.sha256UrlFile(repo.getArchiveUrl(tag), archivePath);
        storedVersions.put(
            version,
            new VersionContext(tag.name(), tag.commit(), sha256, repo.getArchiveStripPrefix(tag)));
      }
    } catch (GitAPIException e) {
      LOG.warnv(
          "[{0}]: Error while fetching metadata from repo {1}",
          monobotConfig.name(), monobotConfig.git().url());
    }
  }

  public void fetch(MonobotConfigFile monobotConfigFile) {
    var monobotConfig = monobotConfigFile.monobotConfig();

    var configDir = monobotConfigFile.configFile().getParent();
    var storedVersions = readVersionsFromConfigFile(configDir);

    var repoUrl = monobotConfig.git().url();
    var repo = ForgeType.getByRepoUrl(repoUrl).newRepo(repoUrl);
    fetchAndPopulate(monobotConfig, repo, storedVersions);

    writeConfigFile(configDir, FILENAME_VERSIONS_JSON, storedVersions);

    var sources = new Sources();
    var sourcesContext = new SourceContext(repo.getArchiveUrlRaw("{commit}"));
    sources.put(repo.getForgeType().getDomain(), sourcesContext);
    var repoConfig = new RepoConfig(sources, storedVersions, null);
    writeConfigFile(configDir, FILENAME_REPO_JSON, repoConfig);
  }

  private void writeConfigFile(Path configDir, String filename, Object object) {
    try {
      objectMapper.writeValue(configDir.resolve(filename).toFile(), object);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }

  private <T> T readConfigFile(File configFile, Class<T> clazz) {
    try {
      return objectMapper.readValue(configFile, clazz);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }

  private Versions readVersionsFromConfigFile(Path configDir) {
    var configFile = configDir.resolve(FILENAME_VERSIONS_JSON).toFile();

    return configFile.exists() ? readConfigFile(configFile, Versions.class) : new Versions();
  }
}
