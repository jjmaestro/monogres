package dev.monogres.monobot.config;

/// What one run does with the catalog it is pointed at.
///
/// The first three read the same tree and ask the same things of the sources; they differ in what
/// they do with the answer. Splitting them apart is what lets the expensive half happen once: a
/// cold `fetch` is gigabytes, and `generate` and `check` over a populated cache are neither.
public enum Mode {
  /// Fills the cache and writes nothing. The download pass, on its own.
  FETCH,

  /// Fills the cache and writes the catalog: `repo.json` and what each archive carried.
  GENERATE,

  /// Fills the cache and compares what it would write against what is committed, without writing
  /// it. A difference fails the entry, which is what makes a committed catalog a gate rather than
  /// a record of the last run.
  CHECK,

  /// Reads each `repo.json` and writes the `monobot.json` it would be generated from. The one mode
  /// that runs the other way and the one that asks nothing of the network.
  IMPORT;

  public boolean writes() {
    return this == GENERATE || this == IMPORT;
  }

  /// Whether a run gets as far as the catalog, as opposed to stopping at the cache. Asked only on
  /// the way through [dev.monogres.monobot.fetch.Fetch], which `import` never reaches.
  public boolean catalogues() {
    return this != FETCH;
  }
}
