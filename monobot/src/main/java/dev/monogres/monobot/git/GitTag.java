package dev.monogres.monobot.git;

import java.net.URL;
import java.util.Collections;
import org.eclipse.jgit.api.Git;
import org.eclipse.jgit.api.errors.GitAPIException;
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

  public static GitTag[] getTags(URL url) throws GitAPIException {
    return Git.lsRemoteRepository()
        .setRemote(url.toString())
        .setTags(true)
        .setHeads(false)
        .call()
        .stream()
        .map(GitTag::new)
        .sorted(Collections.reverseOrder())
        .toArray(GitTag[]::new);
  }

  @Override
  public int compareTo(GitTag o) {
    return name.compareTo(o.name);
  }
}
