package dev.monogres.monobot.config;

import com.fasterxml.jackson.databind.JsonNode;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.TreeMap;

/// Newest first, the way `versions` is ordered in the same document, since both are keyed by
/// version and both order by [NaturalOrder].
///
/// The keys are not always versions. `config/extensions/sslutils/monobot.json` keys this map by
/// distribution, where the same rule is what puts `debian13` above `debian9`.
@RegisterForReflection
public class MetadataContext extends TreeMap<String, JsonNode> {

  private static final long serialVersionUID = 1L;

  public MetadataContext() {
    super(NaturalOrder.ASCENDING.reversed());
  }
}
