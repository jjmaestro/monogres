package dev.monogres.monobot.fetch;

import io.vertx.core.Future;
import io.vertx.core.Handler;
import io.vertx.core.MultiMap;
import io.vertx.core.Promise;
import io.vertx.core.Vertx;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.http.HttpServer;
import io.vertx.core.http.HttpServerRequest;
import io.vertx.ext.web.client.WebClient;
import java.net.ServerSocket;
import java.net.URI;
import java.net.URL;
import java.time.Duration;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/// A forge inside the test JVM, so the real download path can be driven without the network.
///
/// Every `@QuarkusTest` here mocks [SourceArchive#download], which is the outermost method, so
/// nothing below it is reached by any of them: not the request, not the file it opens, not the
/// digest. This starts an HTTP server in process and wires a plain [SourceArchive] to a real
/// [WebClient] pointed at it. No CDI container is needed, because every injection point on
/// [SourceArchive] is a package-private field.
///
/// What a test installs is the whole answer, so the inputs the failure paths need are all
/// reachable: a status code, a body that stops mid-transfer, a connection nothing is listening on,
/// a request that is never answered.
final class DownloadHarness implements AutoCloseable {
  private static final String LOOPBACK = "localhost";
  private static final int ANY_PORT = 0;
  private static final int NOT_MODIFIED = 304;
  private static final long AWAIT_SECONDS = 30;

  private final AtomicReference<Handler<HttpServerRequest>> answer =
      new AtomicReference<>(request -> request.response().end());

  private final List<MultiMap> received = new CopyOnWriteArrayList<>();

  private final Vertx vertx;
  private final WebClient webClient;
  private final HttpServer server;
  private final int port;

  DownloadHarness() {
    vertx = Vertx.vertx();
    webClient = WebClient.create(vertx);
    server =
        vertx
            .createHttpServer()
            .requestHandler(
                request -> {
                  received.add(request.headers());
                  answer.get().handle(request);
                });
    port = await(server.listen(ANY_PORT, LOOPBACK)).actualPort();
  }

  /// Blocks the test thread on a Vert.x future. Bounded, so a request that is never answered
  /// reddens the test rather than hanging the target: the whole suite is one Bazel target with no
  /// timeout of its own.
  static <T> T await(Future<T> future) {
    try {
      return future.toCompletionStage().toCompletableFuture().get(AWAIT_SECONDS, TimeUnit.SECONDS);
    } catch (Exception e) {
      throw new AssertionError(e);
    }
  }

  /// The failure a future settled with, so a test can assert on what it says rather than only that
  /// it happened.
  static Throwable awaitFailure(Future<?> future) {
    var failure = Promise.<Throwable>promise();
    future
        .onSuccess(result -> failure.fail(new AssertionError("the download succeeded: " + result)))
        .onFailure(failure::complete);

    return await(failure.future());
  }

  /// A port nothing is listening on, taken by binding one and giving it straight back. Racy in
  /// principle; nothing else in this JVM asks for a port while a test holds one.
  static int closedPort() {
    try (var socket = new ServerSocket(0)) {
      return socket.getLocalPort();
    } catch (Exception e) {
      throw new AssertionError(e);
    }
  }

  Vertx vertx() {
    return vertx;
  }

  int port() {
    return port;
  }

  URL url(String path) {
    return url(port, path);
  }

  static URL url(int port, String path) {
    try {
      return URI.create("http://" + LOOPBACK + ":" + port + path).toURL();
    } catch (Exception e) {
      throw new AssertionError(e);
    }
  }

  /// [SourceArchive] wired to this forge. `downloadTimeout` is short on purpose: a test that hits
  /// it is a test that would otherwise wait out the target.
  SourceArchive sourceArchive(Duration downloadTimeout) {
    return wire(new SourceArchive(), downloadTimeout);
  }

  /// The same wiring over an instance the test built, for one that overrides something on it.
  <T extends SourceArchive> T wire(T sourceArchive, Duration downloadTimeout) {
    sourceArchive.vertx = vertx;
    sourceArchive.webClient = webClient;
    sourceArchive.downloadTimeout = downloadTimeout;

    return sourceArchive;
  }

  void answer(Handler<HttpServerRequest> handler) {
    answer.set(handler);
  }

  void answerWith(byte[] body) {
    answer(request -> request.response().end(Buffer.buffer(body)));
  }

  void answerWithStatus(int statusCode, String body) {
    answer(request -> request.response().setStatusCode(statusCode).end(body));
  }

  /// Answers with the body and an ETag, and with 304 to anyone who hands that ETag back, which is
  /// what a source that recognizes its own validator does.
  void answerWithEtag(String etag, byte[] body) {
    answer(
        request -> {
          if (etag.equals(request.getHeader("If-None-Match"))) {
            request.response().setStatusCode(NOT_MODIFIED).end();

            return;
          }
          request.response().putHeader("ETag", etag).end(Buffer.buffer(body));
        });
  }

  /// The headers of every request that reached the forge, in the order they arrived.
  List<MultiMap> received() {
    return List.copyOf(received);
  }

  /// Announces a length and then closes the connection partway through, which is what a transfer
  /// cut in the middle looks like to the client.
  void answerTruncated(byte[] body, int bytesSent) {
    answer(
        request -> {
          request
              .response()
              .putHeader("content-length", String.valueOf(body.length))
              .write(Buffer.buffer(Arrays.copyOf(body, bytesSent)));
          request.connection().close();
        });
  }

  /// Accepts the request and answers nothing at all, which is the shape no bound below the request
  /// timeout can see.
  void neverAnswer() {
    answer(request -> {});
  }

  @Override
  public void close() {
    await(server.close());
    webClient.close();
    await(vertx.close());
  }
}
