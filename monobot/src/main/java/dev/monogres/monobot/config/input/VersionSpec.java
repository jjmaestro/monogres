package dev.monogres.monobot.config.input;

import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.Arrays;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;

/// The `versions` block of `monobot.json`: the rules that rewrite a tag name into the string a
/// version is read from.
///
/// `replace` is ordered and the first replacement rule whose regex matches the whole tag name is
/// the one that applies, so the more specific replacement rules should go first. The tags that
/// don't match any replacement rules pass through as-is.
@RegisterForReflection
public record VersionSpec(TagReplacement[] replace) {
  private static final TagReplacement[] PASS_THROUGH = new TagReplacement[0];

  public VersionSpec() {
    this(null);
  }

  public VersionSpec {
    // The spec of a config with no `versions` block: rewrites no tag.
    if (replace == null) {
      replace = PASS_THROUGH;
    }

    var repeated =
        Arrays.stream(replace)
            .collect(Collectors.groupingBy(rule -> rule.regex().pattern(), Collectors.counting()))
            .entrySet()
            .stream()
            .filter(entry -> entry.getValue() > 1)
            .map(Map.Entry::getKey)
            .toList();

    if (!repeated.isEmpty()) {
      throw new IllegalArgumentException(
          "The first replace rule that matches is the one that applies, so a repeated regex is a"
              + " rule that can never apply: "
              + repeated);
    }
  }

  /// The tag name with the first matching rule applied, unchanged when none matches.
  /// `Version.find` decides whether the result is a version.
  public String rewrite(String tagName) {
    return Arrays.stream(replace)
        .map(rule -> rule.appliedTo(tagName))
        .flatMap(Optional::stream)
        .findFirst()
        .orElse(tagName);
  }
}
