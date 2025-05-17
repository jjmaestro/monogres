package dev.monogres.monobot.git;

import org.eclipse.jgit.lib.ObjectId;

public class ObjectIdUtils {
  public static final int SHORT_COMMIT_LENGTH = 7;

  public static String shortCommit(ObjectId objectId) {
    return objectId.abbreviate(SHORT_COMMIT_LENGTH).name();
  }
}
