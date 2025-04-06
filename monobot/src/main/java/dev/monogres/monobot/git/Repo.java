package dev.monogres.monobot.git;

import java.net.URL;

public interface Repo {
  URL getUrl();

  ForgeType getForgeType();

  URL getArchiveUrl(GitTag gitTag);
}
