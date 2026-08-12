package dev.monogres.monobot.catalog;

import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.SequencedMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/// One entry of a `repo.json` `sources` block, materialized the way the Bazel module that reads it
/// does.
///
/// The properties are taken in the order they are written and each is substituted with what is
/// defined by the time it is reached: the version and the source name, then the version context,
/// then every property already materialized. Their order is therefore part of what the document
/// says rather than how it happens to be laid out, which is why `url` is written last and
/// `strip_prefix` after the `name` it is built from.
///
/// A placeholder nothing defines is an error naming both. The alternative is downloading a URL
/// with a brace left in it, and the reader of the same document refuses it too, so this is only
/// the same answer reached sooner.
public record SourceTemplate(String source, SequencedMap<String, String> properties) {
  private static final Pattern PLACEHOLDER = Pattern.compile("\\{([A-Za-z_][A-Za-z0-9_]*)}");

  private static final String SOURCE = "source";
  private static final String VERSION = "version";

  public SourceTemplate {
    properties = new LinkedHashMap<>(properties);
  }

  /// What a materialization starts from. The reader seeds `repo_name` here as well; monobot has no
  /// Bazel repository to name one after, so a document reading it fails rather than materialize a
  /// URL that the reader would materialize differently.
  private Map<String, String> seeded(String version, Map<String, String> versionContext) {
    var context = new LinkedHashMap<String, String>();
    context.put(SOURCE, source);
    context.put(VERSION, version);
    context.putAll(versionContext);

    return context;
  }

  private String substituted(String property, String template, Map<String, String> context) {
    var matcher = PLACEHOLDER.matcher(template);
    var materialized = new StringBuilder();

    while (matcher.find()) {
      var placeholder = matcher.group(1);
      var value = context.get(placeholder);
      if (value == null) {
        throw new IllegalArgumentException(
            source + "." + property + " reads {" + placeholder + "} and nothing defines it");
      }
      matcher.appendReplacement(materialized, Matcher.quoteReplacement(value));
    }

    return matcher.appendTail(materialized).toString();
  }

  /// Every property with its placeholders filled in, which is the seed plus one entry per
  /// property. Returned whole rather than as the `url` alone: `strip_prefix` is materialized by
  /// the same walk, and reporting a download names more than the URL.
  public Map<String, String> materialize(String version, Map<String, String> versionContext) {
    var context = seeded(version, versionContext);
    properties.forEach((key, template) -> context.put(key, substituted(key, template, context)));

    return context;
  }

  /// The placeholders this block reads without defining them first, in the order it reads them.
  /// That is what the version context owes it, and so what a pinned version has to carry beyond
  /// the version string itself.
  public List<String> unboundNames() {
    var defined = new HashSet<>(List.of(SOURCE, VERSION));
    var owed = new LinkedHashSet<String>();

    for (var property : properties.entrySet()) {
      PLACEHOLDER
          .matcher(property.getValue())
          .results()
          .map(match -> match.group(1))
          .filter(name -> !defined.contains(name))
          .forEach(owed::add);
      defined.add(property.getKey());
    }

    return List.copyOf(owed);
  }
}
