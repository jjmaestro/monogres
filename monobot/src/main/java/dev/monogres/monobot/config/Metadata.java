package dev.monogres.monobot.config;

import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.HashMap;

@RegisterForReflection
public class Metadata extends HashMap<String, MetadataContext> {

  private static final long serialVersionUID = 1L;
}
