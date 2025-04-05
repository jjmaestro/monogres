package dev.monogres.monobot.fetch;

import dev.monogres.monobot.config.Config;
import dev.monogres.monobot.git.GitTag;
import java.util.Arrays;
import org.eclipse.jgit.api.Git;
import org.eclipse.jgit.api.errors.GitAPIException;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

public class Fetch {
  private static final Logger LOG = Logger.getLogger(Fetch.class);

  @ConfigProperty(name = "workdir")
  String workdir;

  private static GitTag[] getTags(String url) throws GitAPIException {
    return Git.lsRemoteRepository().setRemote(url).setTags(true).setHeads(false).call().stream()
        .map(GitTag::new)
        .sorted()
        .toArray(GitTag[]::new);
  }

  public static void fetch(Config config) {
    try {
      var tags = getTags(config.git().url());
      System.out.println(Arrays.toString(tags));
    } catch (GitAPIException e) {
      LOG.warnv(
          "[{0}]: Error while fetching metadata from repo {1}", config.name(), config.git().url());
    }
  }
}
