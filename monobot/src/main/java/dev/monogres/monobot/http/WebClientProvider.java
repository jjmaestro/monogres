package dev.monogres.monobot.http;

import io.vertx.core.Vertx;
import io.vertx.ext.web.client.WebClient;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Produces;
import jakarta.inject.Inject;

@ApplicationScoped
public class WebClientProvider {
  @Inject private Vertx vertx;

  @Produces
  public WebClient getWebClient() {
    return WebClient.create(vertx);
  }
}
