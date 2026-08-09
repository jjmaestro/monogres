package dev.monogres.monobot.fetch;

import dev.monogres.monobot.digest.DigestUtils;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import io.vertx.core.file.AsyncFile;
import io.vertx.core.file.OpenOptions;
import io.vertx.ext.web.client.WebClient;
import io.vertx.ext.web.client.predicate.ErrorConverter;
import io.vertx.ext.web.client.predicate.ResponsePredicate;
import io.vertx.ext.web.client.predicate.ResponsePredicateResult;
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
import java.time.Duration;
import java.util.HexFormat;
import java.util.function.Supplier;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

@ApplicationScoped
public class SourceArchive {
  private static final Logger LOG = Logger.getLogger(SourceArchive.class);

  private static final int HTTP_OK = 200;
  private static final int HTTP_MULTIPLE_CHOICES = 300;

  private static final int DIGEST_BLOCK_BYTES = 1024 * 1024;

  @ConfigProperty(name = "downloadTimeout")
  Duration downloadTimeout;

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

    // Truncating, because writing starts at offset 0 without shortening the file: a retry over a
    // longer file left by an earlier attempt would keep that file's tail, and the digest reads the
    // whole file.
    return vertx
        .fileSystem()
        .openBlocking(path.toString(), new OpenOptions().setCreate(true).setTruncateExisting(true));
  }

  /// A response the forge did not mean as an archive. Without this the error page is what gets
  /// written, digested and catalogued, and the run only notices later, when a tar reader refuses
  /// it, by which time the status code that explains it is gone.
  ///
  /// The status and the URL are both named because 429 is the one an operator can act on: both
  /// forges rate limit anonymous callers, and monobot is always an anonymous caller.
  private static ResponsePredicate archiveResponse(URL url) {
    return ResponsePredicate.create(
        response ->
            response.statusCode() >= HTTP_OK && response.statusCode() < HTTP_MULTIPLE_CHOICES
                ? ResponsePredicateResult.success()
                : ResponsePredicateResult.failure(
                    url
                        + " answered HTTP "
                        + response.statusCode()
                        + " "
                        + response.statusMessage()),
        ErrorConverter.create(result -> new IOException(result.message())));
  }

  private Future<Void> downloadFile(URL url, Path path) {
    var writeStream = writableAsyncFile(path);

    return webClient
        // The whole URL, so the scheme decides TLS and the port is the one the URL names rather
        // than the default for its scheme.
        .getAbs(url.toString())
        // A forge that accepts the connection and then stops answering would otherwise hold the
        // download future open forever, and nothing above it settles on its own.
        .timeout(downloadTimeout.toMillis())
        .expect(archiveResponse(url))
        // The codec is told not to close the file, so closing it is this method's job alone and
        // happens on every way out rather than only on the one where the body ended. A connect or
        // DNS failure does not even build a codec, and one descriptor per failed download, held
        // for the rest of the run, is what eventually throws EMFILE out of the next open.
        //
        // AsyncFile.close defers until its outstanding writes have completed, so the future still
        // settles after the last byte reaches the disk.
        .as(BodyCodec.pipe(writeStream, false))
        .send()
        .onSuccess(res -> LOG.infov("Successfully downloaded {0}", url))
        .onFailure(err -> LOG.warnv(err, "Failure downloading {0}", url))
        // Cast because the deprecated Function overload is equally applicable to a method
        // reference.
        .eventually((Supplier<Future<Void>>) writeStream::close)
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
