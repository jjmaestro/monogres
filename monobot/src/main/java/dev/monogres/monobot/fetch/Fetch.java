package dev.monogres.monobot.fetch;

import dev.monogres.monobot.config.input.RepoBotConfig;
import dev.monogres.monobot.config.output.RepoConfig;
import dev.monogres.monobot.config.output.VersionContext;
import dev.monogres.monobot.config.output.VersionContextVariable;
import dev.monogres.monobot.git.ForgeType;
import dev.monogres.monobot.git.GitTag;
import java.net.URL;
import org.eclipse.jgit.api.Git;
import org.eclipse.jgit.api.errors.GitAPIException;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

public class Fetch {
  private static final Logger LOG = Logger.getLogger(Fetch.class);

  @ConfigProperty(name = "workdir")
  String workdir;

  private static GitTag[] getTags(URL url) throws GitAPIException {
    return Git.lsRemoteRepository()
        .setRemote(url.toString())
        .setTags(true)
        .setHeads(false)
        .call()
        .stream()
        .map(GitTag::new)
        .sorted()
        .toArray(GitTag[]::new);
  }

  public static void fetch(RepoBotConfig repoBotConfig) {
    var repoUrl = repoBotConfig.git().url();
    var forgeType = ForgeType.getByRepoUrl(repoUrl);

    try {
      for (var tag : getTags(repoUrl)) {
        var outRepoConfig = new RepoConfig();
        var version = tag.name(); // TODO: version should not be tag name
        var versionContext = new VersionContext();

        var sha256 = "blah";
        var versionContextVariable = new VersionContextVariable();
        versionContextVariable.put(forgeType.getDomain(), sha256);
        versionContext.put("sha256", versionContextVariable);
        outRepoConfig.versions().put(version, versionContext);

        var repo = forgeType.newRepo(repoUrl);
      }
    } catch (GitAPIException e) {
      LOG.warnv(
          "[{0}]: Error while fetching metadata from repo {1}",
          repoBotConfig.name(), repoBotConfig.git().url());
    }
  }
}
