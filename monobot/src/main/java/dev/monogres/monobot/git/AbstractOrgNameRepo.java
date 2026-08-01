package dev.monogres.monobot.git;

import java.net.MalformedURLException;
import java.net.URI;
import java.net.URL;

public abstract class AbstractOrgNameRepo extends AbstractRepo {
  private final String organization;
  private final String name;

  protected AbstractOrgNameRepo(URL url, String organization, String name) {
    super(url);
    this.organization = organization;
    this.name = name;
  }

  public String getOrganization() {
    return organization;
  }

  public String getName() {
    return name;
  }

  /// The forge's archive URL for one commit, or for [Repo#COMMIT_PLACEHOLDER]. The two forms
  /// are built the same way, so only one of them can be a [URL].
  protected abstract String archiveUrl(String commit);

  @Override
  public String getArchiveUrlTemplate() {
    return archiveUrl(COMMIT_PLACEHOLDER);
  }

  @Override
  public URL getArchiveUrl(GitTag gitTag) {
    var uri = URI.create(archiveUrl(gitTag.commit().name()));

    try {
      return uri.toURL();
    } catch (MalformedURLException e) {
      throw new RuntimeException(e);
    }
  }
}
