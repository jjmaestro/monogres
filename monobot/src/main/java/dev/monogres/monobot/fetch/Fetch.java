package dev.monogres.monobot.fetch;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.input.MonobotConfigFile;
import dev.monogres.monobot.config.output.RepoConfig;
import dev.monogres.monobot.config.output.Version;
import dev.monogres.monobot.config.output.VersionContext;
import dev.monogres.monobot.config.output.Versions;
import dev.monogres.monobot.git.ForgeType;
import dev.monogres.monobot.git.GitTag;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.File;
import java.io.IOException;
import java.net.URL;
import java.nio.file.Path;
import org.eclipse.jgit.api.errors.GitAPIException;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class Fetch {
  private static final Logger LOG = Logger.getLogger(Fetch.class);

  private static final String DIR_ARCHIVES = "archives";
  private static final String FILENAME_VERSIONS_JSON = "versions.json";

  @ConfigProperty(name = "workdir")
  String workdir;

  @Inject SourceArchive sourceArchive;

  @Inject ObjectMapper objectMapper;

  private VersionContext generateVersionContext(GitTag tag, URL url, String repoName) {
    var sha256 =
        sourceArchive.sha256UrlFile(
            url, Path.of(workdir, DIR_ARCHIVES, repoName, tag.commit().name() + ".tar.gz"));

    return new VersionContext(tag.name(), tag.commit(), sha256);
  }

  public void fetch(MonobotConfigFile monobotConfigFile) {
    var repoBotConfig = monobotConfigFile.monobotConfig();
    var repoUrl = repoBotConfig.git().url();
    var forgeType = ForgeType.getByRepoUrl(repoUrl);

    try {
      var configDir = monobotConfigFile.configFile().getParent();
      var cachedVersions = readVersionsFromConfigFile(configDir);

      var repoConfig = new RepoConfig();
      var versions = repoConfig.getVersions();

      for (var tag : GitTag.getTags(repoUrl)) {
        var version = new Version(tag.name());
        if (cachedVersions.containsKey(version)) {
          continue;
        }

        var repo = forgeType.newRepo(repoUrl);
        versions.put(
            version, generateVersionContext(tag, repo.getArchiveUrl(tag), repoBotConfig.name()));
      }

      var finalVersions = new Versions();
      finalVersions.putAll(cachedVersions);
      finalVersions.putAll(versions);
      writeConfigFile(configDir, FILENAME_VERSIONS_JSON, finalVersions);
    } catch (GitAPIException e) {
      LOG.warnv(
          "[{0}]: Error while fetching metadata from repo {1}",
          repoBotConfig.name(), repoBotConfig.git().url());
    }
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
