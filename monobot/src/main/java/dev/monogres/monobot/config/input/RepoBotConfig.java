package dev.monogres.monobot.config.input;

public record RepoBotConfig(Version version, String name, Vcs vcs, Git git) {}
