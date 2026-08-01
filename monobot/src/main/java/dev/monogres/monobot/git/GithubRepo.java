package dev.monogres.monobot.git;

import java.net.URL;
import java.text.MessageFormat;

public class GithubRepo extends AbstractOrgNameRepo {
  /**
   * Github supports multiple URLs to download archives. You could be tempted to use the "public"
   * URLs used in the Releases but those are "by tag" and tags can be changed to point to different
   * commits. Github itself recommends:
   *
   * <blockquote>
   * If you rely on stable archives only for reproducibility (ensuring you always get identical
   * files inside your archive), then we recommend you download source archives using the source
   * archives REST API with a commit ID for the :ref parameter.
   * </blockquote>
   *
   * <p>For more info, check this links:
   *
   * <p>Update on the future stability of source code archives and hashes:
   * https://github.blog/open-source/git/update-on-the-future-stability-of-source-code-archives-and-hashes/
   *
   * <p>GH REST API-Download a repository archive(tar):
   * https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28#download-a-repository-archive-tar
   *
   * <p>So, we will use the REST URL and we will use the commit id from the tag. If the commit
   * changes, the SHA256 will change and we will see a failure that should be investigated.
   */
  private static final String ARCHIVE_URL_PATH_MESSAGE_FORMAT_TEMPLATE =
      "https://{0}/repos/{1}/{2}/tarball/{3}";

  private static final String ARCHIVE_URL_EXTENSION_TYPE = "tar.gz";

  /// GitHub repositories are `{org}/{name}` and nothing deeper, which is the one place the two
  /// forges differ about what a repository URL may look like.
  private static String parseUrlItem(URL url, int item) {
    var segments = pathSegments(url);
    if (segments.size() != 2) {
      throw new IllegalArgumentException(
          "Invalid repo URL " + url + ": expected exactly {org}/{name}");
    }

    return segments.get(item);
  }

  private static String parseOrganization(URL url) {
    return parseUrlItem(url, 0);
  }

  private static String parseName(URL url) {
    return parseUrlItem(url, 1);
  }

  public GithubRepo(URL url) {
    super(parseOrganization(url), parseName(url));
  }

  @Override
  public ForgeType getForgeType() {
    return ForgeType.GITHUB;
  }

  @Override
  public String getArchiveUrlExtension() {
    return ARCHIVE_URL_EXTENSION_TYPE;
  }

  @Override
  protected String archiveUrl(String commit) {
    return MessageFormat.format(
        ARCHIVE_URL_PATH_MESSAGE_FORMAT_TEMPLATE,
        getForgeType().getApiDomain(),
        getOrganization(),
        getName(),
        commit);
  }

  @Override
  public String getArchiveStripPrefix(GitTag gitTag) {
    return MessageFormat.format(
        "{0}-{1}-{2}", getOrganization(), getName(), ObjectIdUtils.shortCommit(gitTag.commit()));
  }
}
