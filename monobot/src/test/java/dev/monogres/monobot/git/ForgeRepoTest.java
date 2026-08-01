package dev.monogres.monobot.git;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.net.URI;
import java.net.URL;
import org.eclipse.jgit.lib.ObjectId;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/// The archive URL and the strip prefix are predictions about a third party's archive layout, not
/// readings of the archive that was downloaded: nothing compares either against the tarball. So
/// the formulas themselves are the contract, and this is where they are pinned.
class ForgeRepoTest {
  private static final String COMMIT_SHA = "8cf409d1b669e0e3e22fa79bb54027a4b555e822";
  private static final GitTag TAG = new GitTag("v0.3.0", ObjectId.fromString(COMMIT_SHA));

  private static Repo repo(String repoUrl) {
    var url = url(repoUrl);
    return ForgeType.getRepo(url);
  }

  private static URL url(String repoUrl) {
    try {
      return URI.create(repoUrl).toURL();
    } catch (Exception e) {
      throw new AssertionError(e);
    }
  }

  // ---------------------------------------------------------------- forge selection

  @Test
  void hostSelectsTheForge() {
    assertEquals(ForgeType.GITHUB, ForgeType.getByRepoUrl(url("https://github.com/org/name")));
    assertEquals(ForgeType.GITLAB, ForgeType.getByRepoUrl(url("https://gitlab.com/org/name")));
  }

  @Test
  void unknownHostIsRefused() {
    assertThrows(
        RuntimeException.class, () -> ForgeType.getByRepoUrl(url("https://example.com/org/name")));
  }

  // ---------------------------------------------------------------- github

  @Test
  void githubBuildsTheRestArchiveUrlFromTheCommit() {
    assertEquals(
        "https://api.github.com/repos/theory/pg-envvar/tarball/" + COMMIT_SHA,
        repo("https://github.com/theory/pg-envvar").getArchiveUrl(TAG).toString());
  }

  @Test
  void githubTemplatesTheCommitForTheSourcesBlock() {
    assertEquals(
        "https://api.github.com/repos/theory/pg-envvar/tarball/{commit}",
        repo("https://github.com/theory/pg-envvar").getArchiveUrlTemplate());
  }

  @Test
  void githubStripsOrgNameAndShortCommit() {
    assertEquals(
        "theory-pg-envvar-8cf409d",
        repo("https://github.com/theory/pg-envvar").getArchiveStripPrefix(TAG));
  }

  // ---------------------------------------------------------------- gitlab

  @Test
  void gitlabEncodesTheWholeNamespaceAsTheProjectId() {
    assertEquals(
        "https://gitlab.com/api/v4/projects/ongresinc%2Fextensions%2Fnoset"
            + "/repository/archive.tar.gz?sha="
            + COMMIT_SHA,
        repo("https://gitlab.com/ongresinc/extensions/noset").getArchiveUrl(TAG).toString());
  }

  @Test
  void gitlabTemplatesTheCommitForTheSourcesBlock() {
    assertEquals(
        "https://gitlab.com/api/v4/projects/ongresinc%2Fextensions%2Fnoset"
            + "/repository/archive.tar.gz?sha={commit}",
        repo("https://gitlab.com/ongresinc/extensions/noset").getArchiveUrlTemplate());
  }

  /// GitLab really does serve `<name>-<sha>-<sha>`: the name, the ref it resolved, and the commit
  /// it resolved to, which for a fetch by commit are the same string twice.
  @Test
  void gitlabStripsNameAndTheFullCommitTwice() {
    assertEquals(
        "noset-" + COMMIT_SHA + "-" + COMMIT_SHA,
        repo("https://gitlab.com/ongresinc/extensions/noset").getArchiveStripPrefix(TAG));
  }

  @Test
  void gitlabHandlesTheTwoElementNamespace() {
    var gitlab = repo("https://gitlab.com/group/project");
    assertEquals(
        "https://gitlab.com/api/v4/projects/group%2Fproject/repository/archive.tar.gz?sha={commit}",
        gitlab.getArchiveUrlTemplate());
    assertEquals("project-" + COMMIT_SHA + "-" + COMMIT_SHA, gitlab.getArchiveStripPrefix(TAG));
  }

  // ---------------------------------------------------------------- malformed input

  @Test
  void githubRefusesRepoUrlWithoutOrgAndName() {
    assertThrows(IllegalArgumentException.class, () -> repo("https://github.com/only-one-element"));
  }

  @Test
  void gitlabRefusesRepoUrlWithoutOrgAndName() {
    assertThrows(IllegalArgumentException.class, () -> repo("https://gitlab.com/only-one-element"));
  }

  /// The two shapes of the same URL a person copies out of a browser or a clone command. Neither
  /// forge minds either of them, and both travel: a trailing slash into an empty path segment and
  /// `.git` into the name, where they become an archive URL that 404s and a strip prefix that is
  /// simply wrong, with nothing said about it.
  @ParameterizedTest
  @ValueSource(
      strings = {
        "https://github.com/theory/pg-envvar",
        "https://github.com/theory/pg-envvar/",
        "https://github.com/theory/pg-envvar.git",
        "https://github.com/theory/pg-envvar.git/"
      })
  void githubReadsTheSameRepositoryOutOfEveryFormOfItsUrl(String repoUrl) {
    assertEquals(
        "https://api.github.com/repos/theory/pg-envvar/tarball/{commit}",
        repo(repoUrl).getArchiveUrlTemplate());
    assertEquals("theory-pg-envvar-8cf409d", repo(repoUrl).getArchiveStripPrefix(TAG));
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "https://gitlab.com/ongresinc/extensions/noset",
        "https://gitlab.com/ongresinc/extensions/noset/",
        "https://gitlab.com/ongresinc/extensions/noset.git",
        "https://gitlab.com/ongresinc/extensions/noset.git/"
      })
  void gitlabReadsTheSameRepositoryOutOfEveryFormOfItsUrl(String repoUrl) {
    assertEquals(
        "https://gitlab.com/api/v4/projects/ongresinc%2Fextensions%2Fnoset"
            + "/repository/archive.tar.gz?sha={commit}",
        repo(repoUrl).getArchiveUrlTemplate());
    assertEquals(
        "noset-" + COMMIT_SHA + "-" + COMMIT_SHA, repo(repoUrl).getArchiveStripPrefix(TAG));
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "https://github.com/",
        "https://github.com/theory",
        "https://github.com/theory/",
        "https://gitlab.com/",
        "https://gitlab.com/group",
        "https://gitlab.com/group/",
        "https://github.com/theory/.git"
      })
  void neitherForgeAcceptsUrlThatNamesNoRepository(String repoUrl) {
    var failure = assertThrows(IllegalArgumentException.class, () -> repo(repoUrl));

    assertTrue(
        failure.getMessage().contains(repoUrl),
        "the failure does not name the URL: " + failure.getMessage());
  }
}
