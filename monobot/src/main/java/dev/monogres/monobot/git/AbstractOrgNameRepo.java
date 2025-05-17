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

  @Override
  public String getArchiveUrlRaw(GitTag gitTag) {
    return getArchiveUrlRaw(gitTag.commit().name());
  }

  @Override
  public URL getArchiveUrl(GitTag gitTag) {
    return getArchiveUrl(gitTag.commit().name());
  }

  @Override
  public URL getArchiveUrl(String gitTag) {
    String formattedUrl = getArchiveUrlRaw(gitTag);
    var uri = URI.create(formattedUrl);

    try {
      return uri.toURL();
    } catch (MalformedURLException e) {
      throw new RuntimeException(e);
    }
  }
}
