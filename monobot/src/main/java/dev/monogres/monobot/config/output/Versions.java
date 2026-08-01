package dev.monogres.monobot.config.output;

import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.Comparator;
import java.util.TreeMap;

/// Newest first, the order `repo.json` presents versions in.
@RegisterForReflection
public class Versions extends TreeMap<Version, VersionContext> {

  private static final long serialVersionUID = 1L;

  public Versions() {
    super(Comparator.reverseOrder());
  }
}
