package dev.monogres.monobot.config.output;

import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.HashMap;

@RegisterForReflection
public class Sources extends HashMap<String, SourceContext> {

  private static final long serialVersionUID = 1L;
}
