package dev.monogres.monobot.catalog;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.input.MonobotConfig;
import dev.monogres.monobot.config.input.PinnedVersions;
import dev.monogres.monobot.config.output.RepoConfig;
import dev.monogres.monobot.json.DocumentWriter;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.IOException;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.SequencedMap;
import org.jboss.logging.Logger;

/// Derives the `monobot.json` an entry would be generated from, out of the `repo.json` it already
/// has.
///
/// The catalog was written by hand before monobot could write it, and every decision in it is one
/// monobot cannot make: which host serves the tarball, how a tag spells a version, which Postgres
/// majors an extension supports. So `sources` and `metadata` are carried over as they stand and
/// the versions become pins, which is what they already are. What comes back out of a generate run
/// over the result has to be the `repo.json` it was read from, and that is the whole test.
///
/// Two things it cannot know and says so about: the control file's stem, which is the extension's
/// own name rather than the directory it sits in, and the repository a `discover` block would list
/// tags from, which only a source spelling a forge the usual way gives away.
@ApplicationScoped
public class Import {
  private static final Logger LOG = Logger.getLogger(Import.class);

  private static final String FILENAME_MONOBOT_JSON = "monobot.json";
  private static final String KEY_PIN = "pin";
  private static final String KEY_SOURCES = "sources";

  /// How a source spells a GitHub repository, of the two ways the catalog spells one. Both are
  /// read rather than chosen: which properties a source declares is a decision the document made
  /// before monobot existed.
  private static final List<List<String>> GITHUB_PROPERTIES =
      List.of(List.of("gh_org", "name"), List.of("owner", "repo"));

  @Inject ObjectMapper objectMapper;

  @Inject DocumentWriter documentWriter;

  /// The repository the entry's first source names, where it names one the usual way.
  ///
  /// GitHub only, and deliberately: a GitLab path can carry groups the source properties do not
  /// spell, so `gitlab.com/{org}/{name}` would be a plausible URL pointing at nothing.
  static Optional<String> repositoryUrl(SequencedMap<String, String> source) {
    return GITHUB_PROPERTIES.stream()
        .filter(properties -> properties.stream().allMatch(source::containsKey))
        .findFirst()
        .map(
            properties ->
                "https://github.com/"
                    + source.get(properties.getFirst())
                    + "/"
                    + source.get(properties.getLast()));
  }

  /// The document, built as the map it is written from rather than out of [MonobotConfig], so what
  /// a reader of the file finds in it is only what this decided to put there. Serializing the
  /// config would carry its defaults into all 53 files.
  static SequencedMap<String, Object> documentOf(String name, RepoConfig repoConfig) {
    var pinned = new PinnedVersions();
    repoConfig
        .getVersions()
        .forEach((version, context) -> pinned.put(version, new LinkedHashMap<>(context.derived())));

    var document = new LinkedHashMap<String, Object>();
    document.put("version", 1);
    document.put("name", name);
    repositoryUrl(repoConfig.getSources().firstEntry().getValue())
        .ifPresent(url -> document.put("url", url));
    document.put("sources", repoConfig.getSources());
    document.put("versions", Map.of(KEY_PIN, pinned));
    if (!repoConfig.getMetadata().isEmpty()) {
      document.put("metadata", repoConfig.getMetadata());
    }

    return document;
  }

  /// One entry, from the `repo.json` at `catalogued` to the `monobot.json` beside it. False when
  /// the entry is not one monobot has anything to say about.
  ///
  /// The document is read back into a [MonobotConfig] before it is written, so an import that
  /// produced something monobot cannot read fails here rather than on the next run.
  public boolean entry(Path catalogued) throws IOException {
    var entryDir = catalogued.getParent();
    var name = entryDir.getFileName().toString();
    var catalogueTree = objectMapper.readTree(catalogued.toFile());

    // Decided on the document rather than on whether the model can read it. A contrib extension is
    // built with Postgres and downloaded with nothing, so its entry is a manifest of installed
    // files: a different schema, which keys `versions` by flavor and holds file lists there. It
    // would not parse as an index of archives, and it is not one.
    if (catalogueTree.path(KEY_SOURCES).isEmpty()) {
      LOG.infov("[{0}]: names no source archive, so there is nothing to import", name);

      return false;
    }

    var repoConfig = objectMapper.treeToValue(catalogueTree, RepoConfig.class);
    var document = documentOf(name, repoConfig);
    objectMapper.readValue(documentWriter.render(document), MonobotConfig.class);
    documentWriter.write(entryDir, FILENAME_MONOBOT_JSON, document);

    if (!document.containsKey("url")) {
      LOG.warnv("[{0}]: its sources name no repository to list tags from, so it has no url", name);
    }

    return true;
  }
}
