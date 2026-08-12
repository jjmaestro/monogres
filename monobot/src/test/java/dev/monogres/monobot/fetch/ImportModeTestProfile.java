package dev.monogres.monobot.fetch;

import java.util.HashMap;
import java.util.Map;

/// Reads the catalog the other way round: `repo.json` in, `monobot.json` out.
public class ImportModeTestProfile extends PipelineTestProfile {
  @Override
  public Map<String, String> getConfigOverrides() {
    var overrides = new HashMap<>(super.getConfigOverrides());
    overrides.put("mode", "import");

    return overrides;
  }
}
