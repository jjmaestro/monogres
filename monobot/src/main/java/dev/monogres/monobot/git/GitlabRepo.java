package dev.monogres.monobot.git;

import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.text.MessageFormat;

public class GitlabRepo extends AbstractOrgNameRepo {
  private static final String ARCHIVE_URL_PATH_MESSAGE_FORMAT_TEMPLATE =
      "https://{0}/api/v4/projects/{1}/repository/archive.tar.gz?sha={2}";
  private static final String ARCHIVE_URL_EXTENSION_TYPE = "tar.gz";

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

  @Override
  public String getArchiveUrlExtension() {
    return ARCHIVE_URL_EXTENSION_TYPE;
  }

  /// [Gitlab API id](https://docs.gitlab.com/api/rest/#namespaced-paths)
  private String getApiId() {
    return URLEncoder.encode(getOrganization() + "/" + getName(), StandardCharsets.UTF_8);
  }

  @Override
  public String getArchiveUrlRaw(String gitTag) {
    return MessageFormat.format(
        ARCHIVE_URL_PATH_MESSAGE_FORMAT_TEMPLATE,
        getForgeType().getApiDomain(),
        getApiId(),
        gitTag);
  }

  @Override
  public String getArchiveStripPrefix(GitTag gitTag) {
    return MessageFormat.format("{0}-{1}-{1}", getName(), gitTag.commit().name());
  }
}
