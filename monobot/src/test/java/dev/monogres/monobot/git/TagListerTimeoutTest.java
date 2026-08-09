package dev.monogres.monobot.git;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;

import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.URI;
import java.net.URL;
import java.time.Duration;
import org.junit.jupiter.api.Test;

/// A forge that completes the TCP handshake and then answers nothing. JGit leaves its timeout at
/// zero unless told otherwise, and zero is an infinite connect and read timeout, so this shape
/// holds the call for as long as the process lives. Nothing above it can help: the tag listing runs
/// before the whole-run bound is armed.
class TagListerTimeoutTest {
  private static final Duration TAG_LIST_TIMEOUT = Duration.ofSeconds(2);
  private static final Duration GIVE_UP = Duration.ofSeconds(20);

  /// A socket that is bound and listening but never accepted from. The kernel completes the
  /// handshake out of the backlog queue, so the client connects and then waits for bytes that
  /// never come, which is the read timeout rather than the connect timeout.
  @Test
  void tagListingGivesUpOnaForgeThatNeverAnswers() throws Exception {
    try (var stalled = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      var url = stalledUrl(stalled);
      var tagLister = new TagLister();
      tagLister.tagListTimeout = TAG_LIST_TIMEOUT;

      assertTimeoutPreemptively(
          GIVE_UP, () -> assertThrows(Exception.class, () -> tagLister.getTags(url)));
    }
  }

  private static URL stalledUrl(ServerSocket socket) throws Exception {
    return URI.create("http://localhost:" + socket.getLocalPort() + "/org/name").toURL();
  }
}
