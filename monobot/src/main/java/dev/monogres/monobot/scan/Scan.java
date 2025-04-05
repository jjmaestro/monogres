package dev.monogres.monobot.scan;

import jakarta.enterprise.context.ApplicationScoped;
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

  private List<Path> scanConfigPaths(Path root) throws IOException {
    try (var filesStream =
        Files.walk(root, FileVisitOption.FOLLOW_LINKS)
            .filter(Files::isRegularFile)
            .filter(path -> CONFIG_JSON.equals(path.getFileName().toString()))) {
      return filesStream.collect(Collectors.toList());
    }
  }

  public void run() throws IOException {
    var path = Path.of(rootPath);
    scanConfigPaths(path).forEach(System.out::println);
  }
}
