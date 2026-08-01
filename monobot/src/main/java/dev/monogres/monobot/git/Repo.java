package dev.monogres.monobot.git;

import java.net.URL;

public interface Repo {
  /// What an archive URL template leaves in place of the commit, for whoever reads repo.json to
  /// substitute.
  String COMMIT_PLACEHOLDER = "{commit}";

  URL getUrl();

  ForgeType getForgeType();

  String getArchiveUrlExtension();

  /// The archive URL with [#COMMIT_PLACEHOLDER] where the commit goes. A [String] and not a [URL]
  /// because it is not one: curly braces are illegal in a query part, and Gitlab puts the commit
  /// there, so it becomes a URL only once the placeholder is substituted.
  String getArchiveUrlTemplate();

  URL getArchiveUrl(GitTag gitTag);

  String getArchiveStripPrefix(GitTag gitTag);
}
