package dev.monogres.monobot.fetch;

import java.util.HashMap;
import java.util.Map;

/// Compares what a run would write against what the tree already holds, and writes nothing.
public class CheckModeTestProfile extends PipelineTestProfile {
  @Override
  public Map<String, String> getConfigOverrides() {
    var overrides = new HashMap<>(super.getConfigOverrides());
    overrides.put("mode", "check");

    return overrides;
  }
}
