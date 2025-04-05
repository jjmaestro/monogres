package dev.monogres.monobot.config;

public record Config(Version version, String name, Vcs vcs, Git git) {}
