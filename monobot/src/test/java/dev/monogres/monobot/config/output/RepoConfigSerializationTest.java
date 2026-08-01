package dev.monogres.monobot.config.output;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import com.fasterxml.jackson.databind.ObjectMapper;
import dev.monogres.monobot.config.Metadata;
import dev.monogres.monobot.config.MetadataContext;
import dev.monogres.monobot.git.ForgeType;
import dev.monogres.monobot.git.GitTag;
import dev.monogres.monobot.git.Repo;
import dev.monogres.monobot.json.ConfigObjectMapperCustomizer;
import java.io.IOException;
import java.io.InputStream;
import java.net.MalformedURLException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import org.eclipse.jgit.lib.ObjectId;
import org.junit.jupiter.api.Test;

/// repo.json is consumed by the Monogres Bazel build, so its exact bytes matter: a key that moves
/// between runs shows up there as a spurious diff and a cache miss. This pins the whole document
/// against a golden.
///
/// The mapper is built by applying [ConfigObjectMapperCustomizer] by hand, which is what Quarkus
/// does with it at runtime. Doing that rather than booting a `@QuarkusTest` keeps the test free of
/// the application's required configDir/workdir/monogresRepo properties, and free of augmentation.
class RepoConfigSerializationTest {
  private static final String GOLDEN = "golden/repo.json";

  private static ObjectMapper configuredMapper() {
    var mapper = new ObjectMapper();
    new ConfigObjectMapperCustomizer().customize(mapper);
    return mapper;
  }

  private static Repo nosetRepo() {
    try {
      var url = URI.create("https://gitlab.com/ongresinc/extensions/noset").toURL();
      return ForgeType.getRepo(url);
    } catch (MalformedURLException e) {
      throw new AssertionError(e);
    }
  }

  private static RepoConfig sampleRepoConfig() throws IOException {
    // Both the templated URL and every strip prefix come from the forge that would have produced
    // them, so the golden cannot pin a value the application does not emit.
    var repo = nosetRepo();

    var sources = new Sources();
    sources.put(
        repo.getForgeType().getDomain(),
        new SourceContext(repo.getArchiveUrlTemplate(), repo.getArchiveUrlExtension()));

    // Added ascending on purpose: Versions is a TreeMap that sorts descending, so the golden
    // pins the sort rather than the insertion order.
    var tag020 =
        new GitTag("v0.2.0", ObjectId.fromString("13d4473ae30dc618c8740d9dd0608730e506f799"));
    var tag030 =
        new GitTag("v0.3.0", ObjectId.fromString("8cf409d1b669e0e3e22fa79bb54027a4b555e822"));

    var versions = new Versions();
    versions.put(
        new Version("0.2.0"),
        new VersionContext(
            tag020.name(),
            tag020.commit(),
            "8062260cb4c872fa0dc252a67e5235d8de3207f799e58b7c3588198ff4a1cadf",
            repo.getArchiveStripPrefix(tag020)));
    versions.put(
        new Version("0.3.0"),
        new VersionContext(
            tag030.name(),
            tag030.commit(),
            "17c198106379fbf979ede46096550c48dec623075403d4d6684a00ee8a1be2d3",
            repo.getArchiveStripPrefix(tag030)));

    var json = new ObjectMapper();
    var control = new MetadataContext();
    control.put(
        "0.2.0",
        json.readTree("{\"default_version\":\"0.2.0\",\"superuser\":true,\"trusted\":false}"));
    control.put(
        "0.3.0",
        json.readTree("{\"default_version\":\"0.3.0\",\"superuser\":true,\"trusted\":false}"));

    var compatibleWith = new MetadataContext();
    compatibleWith.put("0.2.0", json.readTree("\">=12, <14\""));
    compatibleWith.put("0.3.0", json.readTree("\">=14\""));

    var metadata = new Metadata();
    metadata.put(".control", control);
    metadata.put("compatible_with", compatibleWith);

    return new RepoConfig(sources, versions, metadata);
  }

  private static String golden() throws IOException {
    try (InputStream in =
        RepoConfigSerializationTest.class.getClassLoader().getResourceAsStream(GOLDEN)) {
      assertNotNull(in, GOLDEN + " is missing from the test resources");
      // The golden is a normal newline-terminated text file; writeValueAsString does not append
      // one, so drop it before comparing.
      return new String(in.readAllBytes(), StandardCharsets.UTF_8).stripTrailing();
    }
  }

  @Test
  void serializesToTheGolden() throws IOException {
    assertEquals(golden(), configuredMapper().writeValueAsString(sampleRepoConfig()));
  }

  /// Jackson caches the serializer it builds for a type, so one serialization can only ever
  /// observe one property order. Re-introspecting with a fresh mapper is what makes an unstable
  /// order observable at all.
  @Test
  void propertyOrderDoesNotDependOnIntrospectionOrder() throws IOException {
    var expected = golden();
    for (int i = 0; i < 20; i++) {
      assertEquals(expected, configuredMapper().writeValueAsString(sampleRepoConfig()));
    }
  }
}
