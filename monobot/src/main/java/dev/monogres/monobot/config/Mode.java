package dev.monogres.monobot.config;

/// What one run does with the catalog it is pointed at.
///
/// All three read the same tree and ask the same things of the sources; they differ in what they
/// do with the answer. Splitting them apart is what lets the expensive half happen once: a cold
/// `fetch` is gigabytes, and `generate` and `check` over a populated cache are neither.
public enum Mode {
  /// Fills the cache and writes nothing. The download pass, on its own.
  FETCH,

  /// Fills the cache and writes the catalog: `repo.json` and what each archive carried.
  GENERATE,

  /// Fills the cache and compares what it would write against what is committed, without writing
  /// it. A difference fails the entry, which is what makes a committed catalog a gate rather than
  /// a record of the last run.
  CHECK;

  public boolean writes() {
    return this == GENERATE;
  }

  public boolean catalogues() {
    return this != FETCH;
  }
}
