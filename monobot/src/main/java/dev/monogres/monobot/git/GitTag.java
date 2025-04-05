package dev.monogres.monobot.git;

import org.eclipse.jgit.lib.Constants;
import org.eclipse.jgit.lib.ObjectId;
import org.eclipse.jgit.lib.Ref;

public record GitTag(String name, ObjectId commit) implements Comparable<GitTag> {
  private static ObjectId getCommitId(Ref reference) {
    return reference.getPeeledObjectId() == null
        ? reference.getObjectId()
        : reference.getPeeledObjectId();
  }

  public GitTag(Ref reference) {
    this(reference.getName().substring(Constants.R_TAGS.length()), getCommitId(reference));
  }

  public boolean referenceIsTag(Ref reference) {
    return reference.getName().startsWith(Constants.R_TAGS);
  }

  @Override
  public int compareTo(GitTag o) {
    return name.compareTo(o.name);
  }
}
