package dev.monogres.monobot.git;

import java.net.URL;
import java.time.Duration;
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

  /// JGit leaves its timeout at zero unless told otherwise, and it propagates that zero to the
  /// transport as an infinite connect and an infinite read timeout, so a forge that completes the
  /// handshake and then answers nothing holds this call for as long as the process lives. The
  /// transport counts in whole seconds, and zero is the value that means no bound, so anything
  /// under a second is raised to one rather than rounded down into it.
  public static GitTag[] getTags(URL url, Duration timeout) throws GitAPIException {
    return Git.lsRemoteRepository()
        .setTimeout((int) Math.max(1L, timeout.toSeconds()))
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
