package dev.monogres.monobot.git;

import java.net.URL;
import java.util.Arrays;

public enum ForgeType {
  GITHUB("github.com", "api.github.com") {
    @Override
    public Repo newRepo(URL repoUrl) {
      return new GithubRepo(repoUrl);
    }
  },
  GITLAB("gitlab.com", "gitlab.com") {
    @Override
    public Repo newRepo(URL repoUrl) {
      return new GitlabRepo(repoUrl);
    }
  };

  private final String domain;
  private final String apiDomain;

  ForgeType(String domain, String apiDomain) {
    this.domain = domain;
    this.apiDomain = apiDomain;
  }

  public String getDomain() {
    return domain;
  }

  public String getApiDomain() {
    return apiDomain;
  }

  public abstract Repo newRepo(URL repoUrl);

  public static ForgeType getByRepoUrl(URL repoUrl) throws RuntimeException {
    var repoHost = repoUrl.getHost();

    return Arrays.stream(ForgeType.values())
        .filter(val -> val.domain.equals(repoHost))
        .findFirst()
        .orElseThrow(() -> new RuntimeException("Invalid Forge type: " + repoHost));
  }

  public static Repo getRepo(URL repoUrl) throws RuntimeException {
    return getByRepoUrl(repoUrl).newRepo(repoUrl);
  }
}
