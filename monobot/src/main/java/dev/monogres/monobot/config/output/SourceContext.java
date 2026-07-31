package dev.monogres.monobot.config.output;

import io.quarkus.runtime.annotations.RegisterForReflection;

@RegisterForReflection
public record SourceContext(String url, String type) {}
