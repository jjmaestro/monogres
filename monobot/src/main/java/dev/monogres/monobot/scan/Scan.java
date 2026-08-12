package dev.monogres.monobot.scan;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.input.MonobotConfig;
import dev.monogres.monobot.config.input.MonobotConfigFile;
import dev.monogres.monobot.fetch.Fetch;
import dev.monogres.monobot.report.RunSummary;
import io.vertx.core.Future;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.IOException;
import java.nio.file.FileVisitOption;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class Scan {
  private static final Logger LOG = Logger.getLogger(Scan.class);

  private static final String CONFIG_JSON = "monobot.json";

  @ConfigProperty(name = "catalogDir")
  String catalogDir;

  @Inject ObjectMapper objectMapper;

  @Inject Fetch fetch;

  @Inject RunSummary summary;

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

  /// Everything an extension needs before its first request: reading its `monobot.json`, reading
  /// the `repo.json` a previous run left, and working out which forge its URL names. Each of those
  /// answers for one extension, and the tree holds one file per extension, so one of them being
  /// unreadable is reported against that extension and leaves the rest of the scan to carry on.
  private Future<Void> scanConfig(Path componentPath) {
    summary.extensionScanned();

    try {
      return fetch.fetch(new MonobotConfigFile(parseComponentConfig(componentPath), componentPath));
    } catch (RuntimeException e) {
      summary.extensionFailed();
      LOG.errorv(e, "[{0}]: cannot be scanned", componentPath);

      return Future.failedFuture(e);
    }
  }

  public Future<Void> run() throws IOException {
    var path = Path.of(catalogDir);

    var fetchFutures = scanConfigPaths(path).stream().map(this::scanConfig).toList();

    if (fetchFutures.isEmpty()) {
      return Future.succeededFuture();
    }

    // Joined rather than all-ed, so this settles when every extension has settled and not when the
    // first one fails. Failing early returns from the run, which tears down Vert.x while the other
    // extensions are still writing, and which of them got as far as their repo.json then depends
    // on how the teardown was timed.
    return Future.join(fetchFutures).mapEmpty();
  }
}
