package dev.monogres.monobot.fetch;

import java.util.HashMap;
import java.util.Map;

/// Checks every cached archive against the digest recorded for it rather than against its length.
public class VerifyDigestTestProfile extends PipelineTestProfile {
  @Override
  public Map<String, String> getConfigOverrides() {
    var overrides = new HashMap<>(super.getConfigOverrides());
    overrides.put("verifyCache", "digest");

    return overrides;
  }
}
