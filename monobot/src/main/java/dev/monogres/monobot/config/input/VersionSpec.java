package dev.monogres.monobot.config.input;

import dev.monogres.monobot.config.output.Version;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.Arrays;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;

/// The `versions` block of `monobot.json`: the rules that rewrite a tag name into the string a
/// version is read from, and which of those versions the catalog keeps.
///
/// `replace` is ordered and the first replacement rule whose regex matches the whole tag name is
/// the one that applies, so the more specific replacement rules should go first. The tags that
/// don't match any replacement rules pass through as-is.
///
/// `satisfy` is a range over the version, `after` a cutoff on the datetime the archive was last
/// modified. Only the archive answers the cutoff, so `after` narrows what is catalogued rather than
/// what is downloaded. `keepNewest` exempts the newest version from that cutoff, so that an
/// extension whose last release predates it still reaches the catalog.
@RegisterForReflection
public record VersionSpec(
    TagReplacement[] replace, String satisfy, String after, boolean keepNewest) {
  private static final TagReplacement[] PASS_THROUGH = new TagReplacement[0];

  public VersionSpec() {
    this(null, null, null, false);
  }

  public VersionSpec {
    // The spec of a config with no `versions` block: rewrites no tag.
    if (replace == null) {
      replace = PASS_THROUGH;
    }

    requireDistinctRules(replace);

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

  /// The tag name with the first matching rule applied, unchanged when none matches.
  /// `Version.find` decides whether the result is a version.
  public String rewrite(String tagName) {
    return Arrays.stream(replace)
        .map(rule -> rule.appliedTo(tagName))
        .flatMap(Optional::stream)
        .findFirst()
        .orElse(tagName);
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
