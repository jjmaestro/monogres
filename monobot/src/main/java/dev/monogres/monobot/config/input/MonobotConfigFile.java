package dev.monogres.monobot.config.input;

import io.quarkus.runtime.annotations.RegisterForReflection;
import java.nio.file.Path;

@RegisterForReflection
public record MonobotConfigFile(MonobotConfig monobotConfig, Path configFile) {}
