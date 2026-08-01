package dev.monogres.monobot.git;

import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.text.MessageFormat;

public class GitlabRepo extends AbstractOrgNameRepo {
  private static final String ARCHIVE_URL_PATH_MESSAGE_FORMAT_TEMPLATE =
      "https://{0}/api/v4/projects/{1}/repository/archive.tar.gz?sha={2}";
  private static final String ARCHIVE_URL_EXTENSION_TYPE = "tar.gz";

  /// GitLab namespaces nest, so everything before the last segment is the organization.
  private static String parseOrganization(URL url) {
    var segments = pathSegments(url);

    return String.join("/", segments.subList(0, segments.size() - 1));
  }

  private static String parseName(URL url) {
    var segments = pathSegments(url);

    return segments.get(segments.size() - 1);
  }

  public GitlabRepo(URL url) {
    super(parseOrganization(url), parseName(url));
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
  protected String archiveUrl(String commit) {
    return MessageFormat.format(
        ARCHIVE_URL_PATH_MESSAGE_FORMAT_TEMPLATE,
        getForgeType().getApiDomain(),
        getApiId(),
        commit);
  }

  @Override
  public String getArchiveStripPrefix(GitTag gitTag) {
    return MessageFormat.format("{0}-{1}-{1}", getName(), gitTag.commit().name());
  }
}
