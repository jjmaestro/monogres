package dev.monogres.monobot.config.input;

import dev.monogres.monobot.config.output.Version;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.SequencedMap;
import java.util.stream.Collectors;

/// The `versions.discover` block: how an entry that follows its upstream reads a tag, and which of
/// the versions it reads are kept.
///
/// An entry without this block asks its forge nothing. Most of the catalog is a set of pins, so
/// most of the catalog lists no tags at all.
///
/// `replace` is ordered and the first rule whose regex matches the whole tag name is the one that
/// applies, so the more specific rules go first. A tag no rule matches is read as it stands.
/// Whatever comes out is the key, so the rule spells the version rather than suggests it:
/// `^v(\d+)\.(\d+)$` to `$1.$2.0` is what turns hll's `v2.21` into `2.21.0`.
///
/// `context` fills the placeholders the `sources` block owes, each from the tag by the same kind
/// of rule: `upstream_version` for hll, `tag_dir` for age, `dirname` for openhalo.
///
/// `satisfy` is a range over the version, `after` a cutoff on the datetime the archive was last
/// modified. Only the archive answers the cutoff, so `after` narrows what is catalogued rather
/// than what is downloaded. `keepNewest` exempts the newest version from that cutoff, so an entry
/// whose last release predates it still reaches the catalog.
@RegisterForReflection
public record DiscoverySpec(
    TagReplacement[] replace,
    Map<String, TagReplacement[]> context,
    String satisfy,
    String after,
    boolean keepNewest) {
  private static final TagReplacement[] PASS_THROUGH = new TagReplacement[0];

  public DiscoverySpec() {
    this(null, null, null, null, false);
  }

  public DiscoverySpec {
    if (replace == null) {
      replace = PASS_THROUGH;
    }
    if (context == null) {
      context = Map.of();
    }

    requireDistinctRules(replace);
    context.values().forEach(DiscoverySpec::requireDistinctRules);

    if (satisfy != null) {
      requireRange(satisfy);
    }
    if (after != null) {
      requireInstant(after);
    }
    if (keepNewest && after == null) {
      throw new IllegalArgumentException("keepNewest requires after");
    }
  }

  private static void requireDistinctRules(TagReplacement[] replace) {
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

  private static void requireRange(String satisfy) {
    if (satisfy.isBlank()) {
      throw new IllegalArgumentException("Empty node-semver ranges satisfy all versions");
    }
    if (!Version.isRange(satisfy)) {
      throw new IllegalArgumentException("invalid node-semver range: " + satisfy);
    }
  }

  private static void requireInstant(String after) {
    try {
      Instant.parse(after);
    } catch (DateTimeParseException e) {
      throw new IllegalArgumentException(
          "Invalid 'after' datetime: " + after + " (" + e.getMessage() + ")", e);
    }
  }

  private static String applied(TagReplacement[] rules, String tagName) {
    return Arrays.stream(rules)
        .map(rule -> rule.appliedTo(tagName))
        .flatMap(Optional::stream)
        .findFirst()
        .orElse(tagName);
  }

  /// The tag name with the first matching rule applied, unchanged when none matches.
  /// `Version.find` decides whether the result is a version.
  public String rewrite(String tagName) {
    return applied(replace, tagName);
  }

  /// The placeholders this tag supplies, which are whatever `context` names. Only the ones a
  /// source block actually reads reach `repo.json`; deriving one nothing reads costs a regex.
  public SequencedMap<String, String> context(String tagName) {
    var derived = new LinkedHashMap<String, String>();
    context.forEach((key, rules) -> derived.put(key, applied(rules, tagName)));

    return derived;
  }

  /// Whether the range keeps this version. Every version, when there is no range.
  public boolean satisfiedBy(Version version) {
    return satisfy == null || version.satisfies(satisfy);
  }

  /// The cutoff an archive has to reach to be kept, when there is one.
  public Optional<Instant> cutoff() {
    return Optional.ofNullable(after).map(Instant::parse);
  }
}
