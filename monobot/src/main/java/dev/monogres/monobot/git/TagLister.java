package dev.monogres.monobot.git;

import jakarta.enterprise.context.ApplicationScoped;
import java.net.URL;
import java.time.Duration;
import org.eclipse.jgit.api.errors.GitAPIException;
import org.eclipse.microprofile.config.inject.ConfigProperty;

/// Lists a repository's tags. This exists so the one network call in the fetch pipeline sits
/// behind an injection point: [GitTag#getTags] is static, and a static call cannot be replaced in
/// a test.
@ApplicationScoped
public class TagLister {
  @ConfigProperty(name = "tagListTimeout")
  Duration tagListTimeout;

  public GitTag[] getTags(URL url) throws GitAPIException {
    return GitTag.getTags(url, tagListTimeout);
  }
}
