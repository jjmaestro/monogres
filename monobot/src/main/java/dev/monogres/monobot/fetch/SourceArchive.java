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
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.HexFormat;
import org.jboss.logging.Logger;

@ApplicationScoped
public class SourceArchive {
  private static final Logger LOG = Logger.getLogger(SourceArchive.class);

  private static final int DIGEST_BLOCK_BYTES = 1024 * 1024;

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

  /// Reads the archive a block at a time and digests it. Blocking, and for as long as the archive
  /// is large.
  ///
  /// Read rather than mapped, because a mapping is addressed by an int and a file over 2 GiB is an
  /// IllegalArgumentException naming Integer.MAX_VALUE. That is not an IOException, so the catch
  /// below cannot see it and an undocumented ceiling on the one value a downstream build pins on
  /// reports itself as a stack trace. A block at a time is also the whole archive out of the page
  /// cache rather than in the address space.
  String sha256(Path path) {
    try (var channel = FileChannel.open(path, StandardOpenOption.READ)) {
      var messageDigest = DigestUtils.getSha256MessageDigest();
      var buffer = ByteBuffer.allocate(DIGEST_BLOCK_BYTES);

      while (channel.read(buffer) != -1) {
        buffer.flip();
        messageDigest.update(buffer);
        buffer.clear();
      }

      return HexFormat.of().formatHex(messageDigest.digest());
    } catch (IOException e) {
      LOG.warnv("I/O error while computing digest of {0}", path.toString());
      throw new RuntimeException(e);
    }
  }

  /// Unordered, because each archive's digest is independent and ordering them would serialize
  /// every download's continuation behind the slowest one.
  Future<String> digest(Path path) {
    return vertx.executeBlocking(() -> sha256(path), false);
  }

  public Future<String> sha256UrlFile(URL url, Path downloadPath) {
    return downloadFile(url, downloadPath).compose(v -> digest(downloadPath));
  }
}
