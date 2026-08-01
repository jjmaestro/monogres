package dev.monogres.monobot.digest;

import java.nio.ByteBuffer;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

public class DigestUtils {
  private static final String JAVA_MESSAGE_DIGEST_SHA256 = "SHA-256";
  private static final HexFormat HEX = HexFormat.of();

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
}
