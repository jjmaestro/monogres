package dev.monogres.monobot.git;

import java.net.MalformedURLException;
import java.net.URI;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.text.MessageFormat;

public class GitlabRepo extends AbstractOrgNameRepo {
  private static String parseOrganization(URL url) {
    var name = parseName(url);

    return url.getPath()
        .substring("/".length(), url.getPath().length() - name.length() - "/".length());
  }

  private static String parseName(URL url) {
    var paths = url.getPath().replaceFirst("^/", "").split("/");
    if (paths.length < 2) {
      throw new IllegalArgumentException("Invalid repo URL " + url);
    }

    return paths[paths.length - 1];
  }

  public GitlabRepo(URL url) {
    super(url, parseOrganization(url), parseName(url));
  }

  @Override
  public ForgeType getForgeType() {
    return ForgeType.GITLAB;
  }

  /// [Gitlab API id](https://docs.gitlab.com/api/rest/#namespaced-paths)
  private String getApiId() {
    return URLEncoder.encode(getOrganization() + "/" + getName(), StandardCharsets.UTF_8);
  }

  @Override
  public URL getArchiveUrl(GitTag gitTag) {
    var uri = URI.create("https://" + getForgeType().getApiDomain());
    var path =
        MessageFormat.format(
            "api/v4/projects/{0}/repository/archive.tar.gz?sha={1}",
            getApiId(), gitTag.commit().name());

    try {
      return uri.resolve(path).toURL();
    } catch (MalformedURLException e) {
      throw new RuntimeException(e);
    }
  }
}
