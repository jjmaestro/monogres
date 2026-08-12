package dev.monogres.monobot.digest;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

public class DigestUtils {
  private static final String JAVA_MESSAGE_DIGEST_SHA256 = "SHA-256";
  private static final HexFormat HEX = HexFormat.of();

  private static final int BLOCK_BYTES = 1024 * 1024;

  private static MessageDigest messageDigestFromAlgorithm(String messageDigestAlgorithm) {
    try {
      return MessageDigest.getInstance(messageDigestAlgorithm);
    } catch (NoSuchAlgorithmException e) {
      // Programming error or JRE that doesn't support this algorithm
      throw new RuntimeException(e);
    }
  }

  public static MessageDigest getSha256MessageDigest() {
    return messageDigestFromAlgorithm(JAVA_MESSAGE_DIGEST_SHA256);
  }

  public static byte[] sha256sumBytes(ByteBuffer byteBuffer) {
    var messageDigest = getSha256MessageDigest();
    messageDigest.update(byteBuffer);

    return messageDigest.digest();
  }

  public static String sha256sum(ByteBuffer byteBuffer) {
    return HEX.formatHex(sha256sumBytes(byteBuffer));
  }

  /// Reads a file a block at a time and digests it. Blocking, and for as long as the file is large.
  ///
  /// Read rather than mapped, because a mapping is addressed by an int and a file over 2 GiB is an
  /// IllegalArgumentException naming Integer.MAX_VALUE. That is not an IOException, so the catch
  /// below cannot see it and an undocumented ceiling on the one value a downstream build pins on
  /// reports itself as a stack trace. A block at a time is also the whole file out of the page
  /// cache rather than in the address space.
  public static String sha256sum(Path path) {
    try (var channel = FileChannel.open(path, StandardOpenOption.READ)) {
      var messageDigest = getSha256MessageDigest();
      var buffer = ByteBuffer.allocate(BLOCK_BYTES);

      while (channel.read(buffer) != -1) {
        buffer.flip();
        messageDigest.update(buffer);
        buffer.clear();
      }

      return HEX.formatHex(messageDigest.digest());
    } catch (IOException e) {
      throw new RuntimeException("Error while digesting " + path, e);
    }
  }
}
