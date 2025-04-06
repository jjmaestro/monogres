package dev.monogres.monobot.config.input;

import java.nio.file.Path;

public record RepoBotConfigFile(RepoBotConfig repoBotConfig, Path configFile) {}
