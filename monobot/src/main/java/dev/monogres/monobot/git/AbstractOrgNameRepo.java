package dev.monogres.monobot.git;

import java.net.MalformedURLException;
import java.net.URI;
import java.net.URL;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Collectors;

public abstract class AbstractOrgNameRepo implements Repo {
  private static final String GIT_SUFFIX = ".git";

  private final String organization;
  private final String name;

  /// The path segments a repository URL names, with the forms a person copies out of a browser or
  /// a clone command reduced to one: empty segments dropped, and the `.git` a clone URL carries
  /// taken off the name.
  ///
  /// Left in, both travel. A trailing slash is an empty segment, which GitLab folds into its
  /// project id as a second `%2F` that the API answers with a 404, and `.git` becomes part of the
  /// name, which makes the archive URL wrong and the strip prefix wrong with nothing said about
  /// either. Every forge here answers to the same URL with or without them.
  protected static List<String> pathSegments(URL url) {
    var segments =
        Arrays.stream(url.getPath().split("/"))
            .filter(segment -> !segment.isEmpty())
            .collect(Collectors.toCollection(ArrayList::new));

    if (!segments.isEmpty()) {
      var last = segments.size() - 1;
      var name = segments.get(last);
      if (name.endsWith(GIT_SUFFIX)) {
        segments.set(last, name.substring(0, name.length() - GIT_SUFFIX.length()));
      }
    }

    if (segments.size() < 2 || segments.get(segments.size() - 1).isEmpty()) {
      throw new IllegalArgumentException(
          "Invalid repo URL " + url + ": expected a path naming an organization and a repository");
    }

    return segments;
  }

  protected AbstractOrgNameRepo(String organization, String name) {
    this.organization = organization;
    this.name = name;
  }

  public String getOrganization() {
    return organization;
  }

  public String getName() {
    return name;
  }

  /// The forge's archive URL for one commit, or for [Repo#COMMIT_PLACEHOLDER]. The two forms
  /// are built the same way, so only one of them can be a [URL].
  protected abstract String archiveUrl(String commit);

  @Override
  public String getArchiveUrlTemplate() {
    return archiveUrl(COMMIT_PLACEHOLDER);
  }

  @Override
  public URL getArchiveUrl(GitTag gitTag) {
    var uri = URI.create(archiveUrl(gitTag.commit().name()));

    try {
      return uri.toURL();
    } catch (MalformedURLException e) {
      throw new RuntimeException(e);
    }
  }
}
