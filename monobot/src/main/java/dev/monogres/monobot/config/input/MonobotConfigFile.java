package dev.monogres.monobot.config.input;

import java.nio.file.Path;

public record MonobotConfigFile(MonobotConfig monobotConfig, Path configFile) {}
