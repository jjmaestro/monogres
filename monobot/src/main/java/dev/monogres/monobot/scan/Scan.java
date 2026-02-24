package dev.monogres.monobot.scan;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.input.MonobotConfig;
import dev.monogres.monobot.config.input.MonobotConfigFile;
import dev.monogres.monobot.fetch.Fetch;
import io.vertx.core.Future;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.IOException;
import java.nio.file.FileVisitOption;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.eclipse.microprofile.config.inject.ConfigProperty;

@ApplicationScoped
public class Scan {
  private static final String CONFIG_JSON = "monobot.json";

  @ConfigProperty(name = "rootPath")
  String rootPath;

  @Inject ObjectMapper objectMapper;

  @Inject Fetch fetch;

  private List<Path> scanConfigPaths(Path root) throws IOException {
    try (var filesStream =
        Files.walk(root, FileVisitOption.FOLLOW_LINKS)
            .filter(Files::isRegularFile)
            .filter(path -> CONFIG_JSON.equals(path.getFileName().toString()))) {
      return filesStream.toList();
    }
  }

  private MonobotConfig parseComponentConfig(Path componentPath) {
    try {
      return objectMapper.readValue(componentPath.toFile(), MonobotConfig.class);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }

  public Future<Void> run() throws IOException {
    var path = Path.of(rootPath);

    var fetchFutures =
        scanConfigPaths(path).stream()
            .map(p -> new MonobotConfigFile(parseComponentConfig(p), p))
            .map(fetch::fetch)
            .toList();

    if (fetchFutures.isEmpty()) {
      return Future.succeededFuture();
    }

    return Future.all(fetchFutures).mapEmpty();
  }
}
