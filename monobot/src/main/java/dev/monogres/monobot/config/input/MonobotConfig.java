package dev.monogres.monobot.config.input;

import com.fasterxml.jackson.annotation.JsonProperty;
import dev.monogres.monobot.config.output.RepoConfigVersion;

public record MonobotConfig(
    @JsonProperty("version") RepoConfigVersion repoConfigVersion, String name, Vcs vcs, Git git) {}
