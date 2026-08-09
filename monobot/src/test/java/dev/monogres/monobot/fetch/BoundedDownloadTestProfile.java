package dev.monogres.monobot.fetch;

import java.util.HashMap;
import java.util.Map;

/// Lowers the download bound far enough that a handful of versions is more than it allows.
public class BoundedDownloadTestProfile extends PipelineTestProfile {
  static final int LIMIT = 2;

  @Override
  public Map<String, String> getConfigOverrides() {
    var overrides = new HashMap<>(super.getConfigOverrides());
    overrides.put("maxConcurrentDownloads", String.valueOf(LIMIT));

    return overrides;
  }
}
