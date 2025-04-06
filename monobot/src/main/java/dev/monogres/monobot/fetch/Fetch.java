package dev.monogres.monobot.fetch;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.input.RepoBotConfigFile;
import dev.monogres.monobot.config.output.RepoConfig;
import dev.monogres.monobot.config.output.VersionContext;
import dev.monogres.monobot.config.output.VersionContextVariable;
import dev.monogres.monobot.git.ForgeType;
import dev.monogres.monobot.git.GitTag;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.net.URL;
import java.nio.file.Path;
import java.util.Collections;
import org.eclipse.jgit.api.Git;
import org.eclipse.jgit.api.errors.GitAPIException;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class Fetch {
  private static final Logger LOG = Logger.getLogger(Fetch.class);

  @ConfigProperty(name = "workdir")
  String workdir;

  @Inject SourceArchive sourceArchive;

  @Inject ObjectMapper objectMapper;

  private static GitTag[] getTags(URL url) throws GitAPIException {
    return Git.lsRemoteRepository()
        .setRemote(url.toString())
        .setTags(true)
        .setHeads(false)
        .call()
        .stream()
        .map(GitTag::new)
        .sorted(Collections.reverseOrder())
        .toArray(GitTag[]::new);
  }

  public void fetch(RepoBotConfigFile repoBotConfigFile) {
    var repoBotConfig = repoBotConfigFile.repoBotConfig();
    var repoUrl = repoBotConfig.git().url();
    var forgeType = ForgeType.getByRepoUrl(repoUrl);

    try {
      var repoConfig = new RepoConfig();

      for (var tag : getTags(repoUrl)) {
        var version = tag.name(); // TODO: version should not be tag name
        var versionContext = new VersionContext();

        var repo = forgeType.newRepo(repoUrl);
        var sha256 =
            sourceArchive.sha256UrlFile(
                repo.getArchiveUrl(tag),
                Path.of(
                    workdir, "archives", repoBotConfig.name(), tag.commit().name() + ".tar.gz"));

        var versionContextVariable = new VersionContextVariable();
        versionContextVariable.put(forgeType.getDomain(), sha256);
        versionContext.put("sha256", versionContextVariable);

        repoConfig.getVersions().put(version, versionContext);
      }

      repoConfig.writeRepoConfig(repoBotConfigFile.configFile().getParent(), objectMapper);
    } catch (GitAPIException e) {
      LOG.warnv(
          "[{0}]: Error while fetching metadata from repo {1}",
          repoBotConfig.name(), repoBotConfig.git().url());
    }
  }
}
