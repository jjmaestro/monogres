package dev.monogres.monobot.fetch;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.catalog.SourceTemplate;
import dev.monogres.monobot.config.input.MonobotConfig;
import dev.monogres.monobot.config.input.MonobotConfigFile;
import dev.monogres.monobot.config.output.RepoConfig;
import dev.monogres.monobot.config.output.Version;
import dev.monogres.monobot.config.output.VersionContext;
import dev.monogres.monobot.config.output.Versions;
import dev.monogres.monobot.fetch.ArchiveMetadataExtractor.ArchiveContents;
import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.TagLister;
import dev.monogres.monobot.json.DocumentWriter;
import dev.monogres.monobot.report.RunSummary;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.net.URI;
import java.net.URL;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Optional;
import java.util.SequencedMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;
import java.util.stream.Stream;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class Fetch {
  private static final Logger LOG = Logger.getLogger(Fetch.class);

  private static final String DIR_BUILD = "build";
  private static final String DIR_METADATA = "metadata";
  private static final String FILENAME_REPO_JSON = "repo.json";

  @ConfigProperty(name = "configDir")
  String configDir;

  @ConfigProperty(name = "monogresRepo")
  String monogresRepo;

  @Inject Vertx vertx;

  @Inject ArchiveCache archiveCache;

  @Inject ObjectMapper objectMapper;

  @Inject DocumentWriter documentWriter;

  @Inject ArchiveMetadataExtractor archiveMetadataExtractor;

  @Inject TagLister tagLister;

  @Inject RunSummary summary;

  /// One version to catalogue, before anything has been asked of the network: the key, whatever
  /// its source templates owe it, and the archive that pair materializes to.
  private record Candidate(Version version, SequencedMap<String, String> context, URL url) {}

  private record Downloaded(Candidate candidate, String sha256, Path archivePath) {}

  /// What one entry has to answer for once the rest of its versions are catalogued. Both are
  /// survivable per version and neither is survivable per entry: a run that met either and said so
  /// only in the log would exit 0 alongside a catalog that is missing a version or holding one
  /// whose archive is not the archive it was written from.
  private record Unanswered(int refused, int disagreed) {
    boolean isEmpty() {
      return refused == 0 && disagreed == 0;
    }

    String describe() {
      var reasons = new ArrayList<String>();

      if (refused > 0) {
        reasons.add(refused + " archives could not be downloaded");
      }
      if (disagreed > 0) {
        reasons.add(disagreed + " digests disagree with what is catalogued");
      }

      return String.join(", ", reasons);
    }
  }

  /// The archive one version names, built from the first source declared. The catalog gives every
  /// entry one source; where there were several they would be mirrors of one archive, and one
  /// digest is what the document records for all of them.
  private static URL archiveUrl(SourceTemplate template, Candidate unresolved) {
    var materialized = template.materialize(unresolved.version().version(), unresolved.context());

    try {
      return URI.create(materialized.get("url")).toURL();
    } catch (IllegalArgumentException | IOException e) {
      throw new IllegalArgumentException(
          "the url " + materialized.get("url") + " is not one that can be fetched", e);
    }
  }

  /// The versions an entry pins, in the order it pins them, which is the order `repo.json` reads.
  private List<Candidate> pinned(MonobotConfig monobotConfig, SourceTemplate template) {
    var owed = template.unboundNames();

    return monobotConfig.versionsSpec().pin().entrySet().stream()
        .map(
            pin -> {
              var missing =
                  owed.stream().filter(name -> !pin.getValue().containsKey(name)).toList();
              if (!missing.isEmpty()) {
                throw new IllegalArgumentException(
                    "version "
                        + pin.getKey()
                        + " is pinned without "
                        + missing
                        + ", which its sources read");
              }

              var context = new LinkedHashMap<>(pin.getValue());
              return new Candidate(
                  pin.getKey(),
                  context,
                  archiveUrl(template, new Candidate(pin.getKey(), context, null)));
            })
        .toList();
  }

  /// The versions the tags name, newest first, less the ones already spoken for. A tag naming no
  /// version and a version outside `satisfy` are ordinary outcomes and are counted rather than
  /// raised.
  private List<Candidate> discovered(
      MonobotConfig monobotConfig, SourceTemplate template, GitTag[] tags, List<Version> taken) {
    var discovery = monobotConfig.versionsSpec().discovery().orElseThrow();
    var found = new ArrayList<Candidate>();
    var versionsNamed = 0;

    for (var tag : tags) {
      var versionFound = Version.find(discovery.rewrite(tag.name()));

      if (versionFound.isEmpty()) {
        summary.versionSkipped(RunSummary.Skipped.NO_VERSION_IN_TAG);
        continue;
      }

      versionsNamed++;
      var version = versionFound.get();
      if (!discovery.satisfiedBy(version)) {
        LOG.infov(
            "[{0}]: Tag {1} ({2}) is outside {3}",
            monobotConfig.label(), tag.name(), version, discovery.satisfy());
        summary.versionSkipped(RunSummary.Skipped.OUTSIDE_SATISFY);
        continue;
      }

      if (taken.contains(version)) {
        summary.versionSkipped(RunSummary.Skipped.ALREADY_STORED);
        continue;
      }

      var context = discovery.context(tag.name());
      found.add(
          new Candidate(
              version, context, archiveUrl(template, new Candidate(version, context, null))));
    }

    if (versionsNamed == 0) {
      LOG.warnv(
          "[{0}]: None of the {1} tags of {2} names a version",
          monobotConfig.label(), tags.length, monobotConfig.repoUrl());
    }

    found.sort((left, right) -> right.version().compareTo(left.version()));

    return found;
  }

  /// The listing is a blocking network round trip, so it runs on a worker rather than on the
  /// thread that asked for it. Run inline, every entry's listing completes before
  /// [dev.monogres.monobot.main.Main] arms `runTimeout`, which leaves the phase with the most
  /// network in it outside the only bound on the process.
  ///
  /// A listing that fails leaves the run carrying on with that entry's pins, since a pin answers
  /// for itself and does not need the tags.
  private Future<List<Candidate>> candidates(
      MonobotConfig monobotConfig, SourceTemplate template, List<Version> stored) {
    var pins = pinned(monobotConfig, template);
    var taken = new ArrayList<>(stored);
    pins.forEach(candidate -> taken.add(candidate.version()));

    if (monobotConfig.versionsSpec().discovery().isEmpty()) {
      return Future.succeededFuture(pins);
    }

    return vertx
        .executeBlocking(() -> tagLister.getTags(monobotConfig.repoUrl()), false)
        .transform(
            listed -> {
              if (listed.failed()) {
                summary.extensionFailed();
                LOG.warnv(
                    listed.cause(),
                    "[{0}]: Error while fetching tags from repo {1}",
                    monobotConfig.label(),
                    monobotConfig.repoUrl());

                return Future.succeededFuture(pins);
              }

              var found = new ArrayList<>(pins);
              found.addAll(discovered(monobotConfig, template, listed.result(), taken));

              return Future.succeededFuture(List.copyOf(found));
            });
  }

  /// How many of this entry's archives the source would not serve. Each download recovers into an
  /// empty result rather than failing, because one archive answers for one version: a composite
  /// that fails on the first refusal discards the versions that downloaded beside it, and does it
  /// while they are still in flight.
  private Future<List<Optional<Downloaded>>> download(
      MonobotConfig monobotConfig, Path entry, List<Candidate> candidates, AtomicInteger refused) {
    var downloads =
        candidates.stream()
            .map(
                candidate ->
                    archiveCache
                        .archive(entry, candidate.version(), candidate.url())
                        .map(
                            cached -> {
                              // Logged here rather than beside the request, which knows the URL and
                              // not the entry it belongs to, so attributing a download meant
                              // reversing the URL.
                              LOG.infov(
                                  "[{0}]: {1} is at {2}",
                                  monobotConfig.label(), candidate.version(), cached.archive());

                              return Optional.of(
                                  new Downloaded(candidate, cached.sha256(), cached.archive()));
                            })
                        .recover(
                            err -> {
                              refused.incrementAndGet();
                              summary.versionSkipped(RunSummary.Skipped.REFUSED_DOWNLOAD);
                              LOG.errorv(
                                  err,
                                  "[{0}]: {1} could not be downloaded from {2}",
                                  monobotConfig.label(),
                                  candidate.version(),
                                  candidate.url());

                              return Future.succeededFuture(Optional.<Downloaded>empty());
                            }))
            .toList();

    if (downloads.isEmpty()) {
      return Future.succeededFuture(List.of());
    }

    return Future.all(downloads)
        .map(
            composite ->
                IntStream.range(0, composite.size())
                    .mapToObj(composite::<Optional<Downloaded>>resultAt)
                    .toList());
  }

  /// Whether an archive is recent enough to catalogue, which requires downloading the archive.
  ///
  /// `keepNewest` spares one version, and which one is named rather than left to the order the
  /// downloads happen to complete in: the newest of everything this run knows about.
  private boolean isRecentEnough(
      MonobotConfig monobotConfig,
      Downloaded result,
      Optional<Version> newest,
      Instant lastModified) {
    var discovery = monobotConfig.versionsSpec().discovery();
    var cutoff = discovery.flatMap(spec -> spec.cutoff());

    if (cutoff.isEmpty()
        || (discovery.get().keepNewest()
            && newest.filter(result.candidate().version()::equals).isPresent())) {
      return true;
    }

    var isRecentEnough = !lastModified.isBefore(cutoff.get());

    if (!isRecentEnough) {
      LOG.infov(
          "[{0}]: {1} was last modified {2}, before the cutoff {3}",
          monobotConfig.label(), result.candidate().version(), lastModified, cutoff.get());
    }

    return isRecentEnough;
  }

  /// Whether what the archive digests to is what the catalog already records for this version.
  ///
  /// A version in the catalog names one archive, so its digest is settled. The same URL answering
  /// with different bytes is the artifact changing under a pin, which is the one thing a catalog of
  /// digests exists to notice, and recording the new digest would notice it silently. So the stored
  /// digest stays and the entry fails, with both digests named: what to do about it is a decision
  /// about the artifact, and nobody can take it from a `git diff` that has already been taken.
  private boolean agreesWithTheCatalogue(
      MonobotConfig monobotConfig, Downloaded result, Versions stored) {
    var catalogued = stored.get(result.candidate().version());

    if (catalogued == null
        || catalogued.sha256() == null
        || catalogued.sha256().equals(result.sha256())) {
      return true;
    }

    LOG.errorv(
        "[{0}]: {1} is catalogued as sha256 {2}, and {3} digests to {4}",
        monobotConfig.label(),
        result.candidate().version(),
        catalogued.sha256(),
        result.archivePath(),
        result.sha256());

    return false;
  }

  /// What the catalog records about one version. The archive is read first so a version it cannot
  /// answer for is left out altogether rather than recorded against an archive nothing could open.
  ///
  /// What the archive carried is written twice over: as it stands, into the cache beside the
  /// archive itself, and parsed, into the catalog beside the entry. The cache keeps the bytes a
  /// question about the parsing has to be settled against; the catalog keeps what a build reads.
  private void catalogue(
      MonobotConfig monobotConfig,
      Downloaded result,
      ArchiveContents contents,
      Versions versions,
      Path outputDir) {
    versions.put(
        result.candidate().version(),
        new VersionContext(result.candidate().context(), result.sha256()));
    archiveCache.storeExtracted(
        result.archivePath().getParent(), monobotConfig.controlStem().orElse(null), contents);
    writeExtracted(monobotConfig, result.candidate().version(), contents, outputDir);
  }

  /// The control file and the PGXN metadata the archive carried, written beside the entry rather
  /// than into it. `repo.json` has no place for either: it is an index of archives, and the Bazel
  /// build reads its `metadata` block for decisions monobot does not make.
  ///
  /// One directory per version, so the file a question is about is the file at that path.
  private void writeExtracted(
      MonobotConfig monobotConfig, Version version, ArchiveContents contents, Path outputDir) {
    var into = outputDir.resolve(DIR_METADATA).resolve(version.version());

    if (contents.control() != null) {
      documentWriter.write(
          into, "control.json", archiveMetadataExtractor.controlOf(contents.control()));
    }
    if (contents.metaJson() != null) {
      documentWriter.write(
          into, "META.json", archiveMetadataExtractor.metaJsonOf(contents.metaJson()));
    }
    if (contents.control() == null && monobotConfig.controlStem().isPresent()) {
      LOG.warnv(
          "[{0}]: {1} carries no {0}.control, so nothing is written for it",
          monobotConfig.label(), version);
    }
  }

  public Future<Void> fetch(MonobotConfigFile monobotConfigFile) {
    var monobotConfig = monobotConfigFile.monobotConfig();

    if (monobotConfig.disabled()) {
      LOG.infov("[{0}]: is disabled, so nothing is asked of it", monobotConfig.label());

      return Future.succeededFuture();
    }

    var monobotConfigDir = monobotConfigFile.configFile().getParent();
    var relPath = Path.of(configDir).relativize(monobotConfigDir);
    var outputDir = Path.of(monogresRepo, DIR_BUILD).resolve(relPath);
    var storedRepo = readOrCreateRepoConfig(outputDir.resolve(FILENAME_REPO_JSON).toFile());
    var stored = storedRepo.getVersions() == null ? new Versions() : storedRepo.getVersions();

    var template = monobotConfig.sources().templates().getFirst();
    var refused = new AtomicInteger();
    var disagreed = new AtomicInteger();

    return candidates(monobotConfig, template, List.copyOf(stored.keySet()))
        .compose(candidates -> download(monobotConfig, relPath, candidates, refused))
        .compose(
            downloaded ->
                vertx.executeBlocking(
                    () -> {
                      var kept = downloaded.stream().flatMap(Optional::stream).toList();
                      var newest =
                          Stream.concat(
                                  kept.stream().map(Downloaded::candidate).map(Candidate::version),
                                  stored.keySet().stream())
                              .max(Version::compareTo);
                      var versions = new Versions();

                      for (var result : kept) {
                        try {
                          // One read per archive, answering both the cutoff and what the archive
                          // carries. Gunzipping and walking a whole tarball is the most expensive
                          // thing this program does per version, and this block is ordered, so
                          // every one of them serialises behind the last.
                          var contents =
                              archiveMetadataExtractor.read(
                                  monobotConfig.controlStem().orElse(null), result.archivePath());
                          if (!agreesWithTheCatalogue(monobotConfig, result, stored)) {
                            disagreed.incrementAndGet();
                            summary.versionSkipped(RunSummary.Skipped.DIGEST_DISAGREES);
                          } else if (isRecentEnough(
                              monobotConfig, result, newest, contents.lastModified())) {
                            catalogue(monobotConfig, result, contents, versions, outputDir);
                            summary.versionAdded();
                          } else {
                            summary.versionSkipped(RunSummary.Skipped.BEFORE_CUTOFF);
                          }
                        } catch (RuntimeException e) {
                          summary.versionSkipped(RunSummary.Skipped.UNREADABLE_ARCHIVE);
                          LOG.errorv(
                              e,
                              "[{0}]: {1} has an archive that cannot be read",
                              monobotConfig.label(),
                              result.candidate().version());
                        }
                      }

                      writeRepoConfig(monobotConfig, versions, stored, outputDir);

                      return new Unanswered(refused.get(), disagreed.get());
                    }))
        // Reported after the catalogue has been written rather than instead of writing it: the
        // versions that came through are as good as they would have been on their own, and the
        // ones that did not are what the run has to answer for.
        .compose(
            unanswered -> {
              if (unanswered.isEmpty()) {
                return Future.<Void>succeededFuture();
              }
              summary.extensionFailed();

              return Future.<Void>failedFuture(
                  new IOException("[" + monobotConfig.label() + "]: " + unanswered.describe()));
            });
  }

  /// The document is `monobot.json`'s `sources` and `metadata` as they stand, plus the versions
  /// this run answered for and the ones a previous run recorded that it did not reach.
  ///
  /// A version whose archive was not downloaded this run keeps the digest already stored for it,
  /// so a forge that refuses one archive does not cost the catalog every other version in the
  /// entry.
  private void writeRepoConfig(
      MonobotConfig monobotConfig, Versions versions, Versions stored, Path outputDir) {
    var merged = new Versions();
    var pins = monobotConfig.versionsSpec().pin().keySet();

    // Pinned first and in the order they are pinned, which is the one thing the document states
    // outright. babelfish pins 4.0 before 5.1 and means it.
    pins.forEach(
        version -> {
          var context = versions.getOrDefault(version, stored.get(version));
          if (context != null) {
            merged.put(version, context);
          }
        });

    // Then whatever the tags turned up and whatever a previous run left, newest first, which is
    // how an entry that follows its upstream reads.
    var rest = new ArrayList<Version>();
    versions.keySet().stream().filter(version -> !pins.contains(version)).forEach(rest::add);
    stored.keySet().stream()
        .filter(version -> !pins.contains(version) && !versions.containsKey(version))
        .forEach(rest::add);
    rest.sort(Comparator.reverseOrder());
    rest.forEach(
        version -> merged.put(version, versions.getOrDefault(version, stored.get(version))));

    if (merged.isEmpty()) {
      LOG.warnv(
          "[{0}]: no version was catalogued, so no repo.json is written", monobotConfig.label());

      return;
    }

    documentWriter.write(
        outputDir,
        FILENAME_REPO_JSON,
        new RepoConfig(monobotConfig.sources(), merged, monobotConfig.metadata()));
    summary.catalogWritten();
  }

  private RepoConfig readOrCreateRepoConfig(File repoConfigFile) {
    var repoConfig = readConfigFile(repoConfigFile, RepoConfig.class);

    return repoConfig == null ? new RepoConfig() : repoConfig;
  }

  private <T> T readConfigFile(File configFile, Class<T> clazz) {
    try {
      return objectMapper.readValue(configFile, clazz);
    } catch (FileNotFoundException e) {
      return null;
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }
}
