package dev.monogres.monobot.scan;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.Config;
import dev.monogres.monobot.fetch.Fetch;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.IOException;
import java.nio.file.FileVisitOption;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Collectors;
import org.eclipse.microprofile.config.inject.ConfigProperty;

@ApplicationScoped
public class Scan {
  private static final String CONFIG_JSON = "monobot.json";

  @ConfigProperty(name = "rootPath")
  String rootPath;

  @Inject ObjectMapper objectMapper;

  private List<Path> scanConfigPaths(Path root) throws IOException {
    try (var filesStream =
        Files.walk(root, FileVisitOption.FOLLOW_LINKS)
            .filter(Files::isRegularFile)
            .filter(path -> CONFIG_JSON.equals(path.getFileName().toString()))) {
      return filesStream.collect(Collectors.toList());
    }
  }

  private Config parseComponentConfig(Path componentPath) {
    try {
      return objectMapper.readValue(componentPath.toFile(), Config.class);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }

  public void run() throws IOException {
    var path = Path.of(rootPath);
    scanConfigPaths(path).stream().map(this::parseComponentConfig).forEach(Fetch::fetch);
  }
}
