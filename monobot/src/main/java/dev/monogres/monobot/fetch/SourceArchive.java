package dev.monogres.monobot.fetch;

import dev.monogres.monobot.digest.DigestUtils;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import io.vertx.core.file.AsyncFile;
import io.vertx.core.file.OpenOptions;
import io.vertx.ext.web.client.WebClient;
import io.vertx.ext.web.codec.BodyCodec;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.IOException;
import java.net.URL;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import org.jboss.logging.Logger;

@ApplicationScoped
public class SourceArchive {
  private static final Logger LOG = Logger.getLogger(SourceArchive.class);

  @Inject Vertx vertx;

  @Inject WebClient webClient;

  private void createDownloadDir(Path path) {
    var downloadDir = path.getParent();
    try {
      Files.createDirectories(downloadDir);
    } catch (IOException e) {
      throw new RuntimeException(e);
    }
  }

  private AsyncFile writableAsyncFile(Path path) {
    createDownloadDir(path);

    return vertx.fileSystem().openBlocking(path.toString(), new OpenOptions().setCreate(true));
  }

  private Future<Void> downloadFile(URL url, Path path) {
    var writeStream = writableAsyncFile(path);

    return webClient
        .get(
            "https".equals(url.getProtocol()) ? 443 : 80,
            url.getHost(),
            null == url.getQuery() ? url.getPath() : url.getPath() + "?" + url.getQuery())
        .ssl(true)
        .as(BodyCodec.pipe(writeStream))
        .send()
        .onSuccess(res -> LOG.infov("Successfully downloaded {0}", url))
        .onFailure(err -> LOG.warnv(err, "Failure downloading {0}", url))
        .mapEmpty();
  }

  public Future<String> sha256UrlFile(URL url, Path downloadPath) {
    return downloadFile(url, downloadPath)
        .map(
            v -> {
              try (var fc = FileChannel.open(downloadPath, StandardOpenOption.READ)) {
                var buffer = fc.map(FileChannel.MapMode.READ_ONLY, 0L, fc.size());
                return DigestUtils.sha256sum(buffer);
              } catch (IOException e) {
                LOG.warnv("I/O error while computing digest of {0}", downloadPath.toString());
                throw new RuntimeException(e);
              }
            });
  }
}
