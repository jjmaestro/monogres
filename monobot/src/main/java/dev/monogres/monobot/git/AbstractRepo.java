package dev.monogres.monobot.git;

import java.net.URL;

public abstract class AbstractRepo implements Repo {
  private final URL url;

  protected AbstractRepo(URL url) {
    this.url = url;
  }

  @Override
  public URL getUrl() {
    return url;
  }
}
