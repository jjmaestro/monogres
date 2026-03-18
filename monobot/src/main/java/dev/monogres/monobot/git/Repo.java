package dev.monogres.monobot.git;

import java.net.URL;

public interface Repo {
  URL getUrl();

  ForgeType getForgeType();

  String getArchiveUrlExtension();

  String getArchiveUrlRaw(GitTag gitTag);

  String getArchiveUrlRaw(String gitTag);

  URL getArchiveUrl(GitTag gitTag);

  URL getArchiveUrl(String gitTag);

  String getArchiveStripPrefix(GitTag gitTag);
}
