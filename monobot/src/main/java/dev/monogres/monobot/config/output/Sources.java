package dev.monogres.monobot.config.output;

import dev.monogres.monobot.catalog.SourceTemplate;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.LinkedHashMap;
import java.util.List;

/// The `sources` block, carried from `monobot.json` to `repo.json` as it was written.
///
/// Ordered twice over, and neither order is cosmetic. The sources are tried in the order they are
/// declared, and within one source a property may only read what is declared above it, so a map
/// that sorted either would say something the document does not.
///
/// Untyped on purpose: a source declares whatever properties its URL is spelled from, and the
/// catalog spells them `gh_org` and `name` in one entry, `owner` and `repo` in another. Naming
/// them here would be inventing a schema the reader of the document does not have.
@RegisterForReflection
public class Sources extends LinkedHashMap<String, LinkedHashMap<String, String>> {

  private static final long serialVersionUID = 1L;

  public List<SourceTemplate> templates() {
    return entrySet().stream()
        .map(source -> new SourceTemplate(source.getKey(), source.getValue()))
        .toList();
  }

  /// Every placeholder any source reads without declaring it first, which is what each version has
  /// to carry beyond its own string.
  public List<String> unboundNames() {
    return templates().stream()
        .flatMap(template -> template.unboundNames().stream())
        .distinct()
        .toList();
  }
}
