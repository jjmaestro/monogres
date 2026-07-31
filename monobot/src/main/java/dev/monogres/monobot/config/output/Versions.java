package dev.monogres.monobot.config.output;

import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.TreeMap;

@RegisterForReflection
public class Versions extends TreeMap<Version, VersionContext> {

  private static final long serialVersionUID = 1L;
}
