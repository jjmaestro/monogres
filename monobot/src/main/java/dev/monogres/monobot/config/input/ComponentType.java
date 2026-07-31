package dev.monogres.monobot.config.input;

import io.quarkus.runtime.annotations.RegisterForReflection;

@RegisterForReflection
public enum ComponentType {
  POSTGRES,
  EXTENSION
}
