package dev.monogres.monobot.fetch;

import dev.monogres.monobot.digest.DigestUtils;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import io.vertx.core.file.AsyncFile;
import io.vertx.core.file.OpenOptions;
import io.vertx.ext.web.client.HttpRequest;
import io.vertx.ext.web.client.HttpResponse;
import io.vertx.ext.web.client.WebClient;
import io.vertx.ext.web.client.predicate.ErrorConverter;
import io.vertx.ext.web.client.predicate.ResponsePredicate;
import io.vertx.ext.web.client.predicate.ResponsePredicateResult;
import io.vertx.ext.web.codec.BodyCodec;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.io.IOException;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Duration;
import java.util.Optional;
import java.util.function.Supplier;
import org.eclipse.microprofile.config.inject.ConfigProperty;

@ApplicationScoped
public class SourceArchive {
  private static final int HTTP_OK = 200;
  private static final int HTTP_MULTIPLE_CHOICES = 300;
  private static final int HTTP_NOT_MODIFIED = 304;

  private static final String HEADER_ETAG = "ETag";
  private static final String HEADER_IF_MODIFIED_SINCE = "If-Modified-Since";
  private static final String HEADER_IF_NONE_MATCH = "If-None-Match";
  private static final String HEADER_LAST_MODIFIED = "Last-Modified";

  private static final String SUFFIX_PARTIAL = ".part";

  @ConfigProperty(name = "downloadTimeout")
  Duration downloadTimeout;

  @Inject Vertx vertx;

  @Inject WebClient webClient;

  /// What a source answered with. `sha256` and `size` describe the file now on disk; `etag` and
  /// `lastModified` are the validators to hand back on the next request, and are null when the
  /// source offered neither.
  public record Download(String sha256, long size, String etag, String lastModified) {}

  /// The validators a source gave for an archive, as it spelled them. Opaque on purpose: their only
  /// use is being repeated back, and a source that recognizes one answers 304.
  public record Validators(String etag, String lastModified) {}

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

  /// Where the response is written while it is arriving. The body codec needs a file to pipe into
  /// before the request is even sent, so writing straight to the archive path would truncate a
  /// perfectly good cached archive on the way to being told it has not changed, and would leave
  /// half of one there when a transfer is cut.
  static Path partialPath(Path path) {
    return path.resolveSibling(path.getFileName() + SUFFIX_PARTIAL);
  }

  /// A response the source did not mean as an archive. Without this the error page is what gets
  /// written, digested and catalogued, and the run only notices later, when a tar reader refuses
  /// it, by which time the status code that explains it is gone.
  ///
  /// The status and the URL are both named because 429 is the one an operator can act on: both
  /// forges rate limit anonymous callers, and monobot is always an anonymous caller.
  ///
  /// 304 passes only when the request carried validators to earn it. Unasked for, it is a source
  /// answering about bytes the caller never claimed to have.
  private static ResponsePredicate archiveResponse(URL url, boolean conditional) {
    return ResponsePredicate.create(
        response ->
            isArchive(response.statusCode()) || (conditional && isUnchanged(response.statusCode()))
                ? ResponsePredicateResult.success()
                : ResponsePredicateResult.failure(
                    url
                        + " answered HTTP "
                        + response.statusCode()
                        + " "
                        + response.statusMessage()),
        ErrorConverter.create(result -> new IOException(result.message())));
  }

  private static boolean isArchive(int statusCode) {
    return statusCode >= HTTP_OK && statusCode < HTTP_MULTIPLE_CHOICES;
  }

  private static boolean isUnchanged(int statusCode) {
    return statusCode == HTTP_NOT_MODIFIED;
  }

  private static HttpRequest<?> conditionOn(HttpRequest<?> request, Validators validators) {
    if (validators.etag() != null) {
      request.putHeader(HEADER_IF_NONE_MATCH, validators.etag());
    }
    if (validators.lastModified() != null) {
      request.putHeader(HEADER_IF_MODIFIED_SINCE, validators.lastModified());
    }

    return request;
  }

  private Future<HttpResponse<Void>> request(URL url, Path partial, Validators validators) {
    var writeStream = writableAsyncFile(partial);
    var request =
        webClient
            // The whole URL, so the scheme decides TLS and the port is the one the URL names rather
            // than the default for its scheme.
            .getAbs(url.toString())
            // A source that accepts the connection and then stops answering would otherwise hold
            // the download future open forever, and nothing above it settles on its own.
            .timeout(downloadTimeout.toMillis())
            .expect(archiveResponse(url, validators != null));

    if (validators != null) {
      conditionOn(request, validators);
    }

    return request
        // The codec is told not to close the file, so closing it is this method's job alone and
        // happens on every way out rather than only on the one where the body ended. A connect or
        // DNS failure does not even build a codec, and one descriptor per failed download, held
        // for the rest of the run, is what eventually throws EMFILE out of the next open.
        //
        // AsyncFile.close defers until its outstanding writes have completed, so the future still
        // settles after the last byte reaches the disk.
        .as(BodyCodec.pipe(writeStream, false))
        .send()
        // Not logged here. This knows the URL and not the extension it belongs to, and every other
        // message in the pipeline is prefixed with the extension, so a line from here could only be
        // attributed by reversing the URL. The caller has both and reports it.

        // Cast because the deprecated Function overload is equally applicable to a method
        // reference.
        .eventually((Supplier<Future<Void>>) writeStream::close);
  }

  /// Moves the response onto the archive path and reads back what the cache records about it. One
  /// worker task for the move, the stat and the digest together, so the file is walked once.
  private Future<Download> settle(Path partial, Path path, HttpResponse<Void> response) {
    return vertx.executeBlocking(
        () -> {
          try {
            Files.move(
                partial, path, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);

            return new Download(
                sha256(path),
                Files.size(path),
                response.getHeader(HEADER_ETAG),
                response.getHeader(HEADER_LAST_MODIFIED));
          } catch (IOException e) {
            throw new RuntimeException(e);
          }
        },
        false);
  }

  private Future<Optional<Download>> fetch(URL url, Path path, Validators validators) {
    var partial = partialPath(path);

    return request(url, partial, validators)
        .compose(
            response ->
                isUnchanged(response.statusCode())
                    ? Future.succeededFuture(Optional.<Download>empty())
                    : settle(partial, path, response).map(Optional::of))
        // Whatever happened, the partial file has no reader: on the way out of a completed download
        // it has already been moved, and on every other way out it holds a response nothing can
        // use.
        .eventually(
            (Supplier<Future<Void>>)
                () ->
                    vertx
                        .executeBlocking(() -> Files.deleteIfExists(partial), false)
                        .<Void>mapEmpty());
  }

  /// The whole archive, written to `path` and digested.
  public Future<Download> download(URL url, Path path) {
    return fetch(url, path, null).map(Optional::orElseThrow);
  }

  /// The archive again, asked for with the validators the cache holds. Empty when the source
  /// answered that what is already at `path` is current, which leaves that file untouched.
  public Future<Optional<Download>> refresh(URL url, Path path, Validators validators) {
    return fetch(url, path, validators);
  }

  /// Its own method so a test can say which thread the digest ran on. Digesting reads every byte
  /// of the archive, and the response's continuation runs on the event loop that received it.
  String sha256(Path path) {
    return DigestUtils.sha256sum(path);
  }
}
