package dev.monogres.monobot.fetch;

import java.util.HashMap;
import java.util.Map;

/// Asks the source about every archive, including the ones the cache can already answer for.
public class RefreshCacheTestProfile extends PipelineTestProfile {
  @Override
  public Map<String, String> getConfigOverrides() {
    var overrides = new HashMap<>(super.getConfigOverrides());
    overrides.put("refreshCache", "true");

    return overrides;
  }
}
