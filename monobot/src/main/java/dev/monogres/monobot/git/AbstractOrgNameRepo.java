package dev.monogres.monobot.git;

import java.net.URL;

public abstract class AbstractOrgNameRepo extends AbstractRepo {
  private final String organization;
  private final String name;

  protected AbstractOrgNameRepo(URL url, String organization, String name) {
    super(url);
    this.organization = organization;
    this.name = name;
  }

  public String getOrganization() {
    return organization;
  }

  public String getName() {
    return name;
  }
}
