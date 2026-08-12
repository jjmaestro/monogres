package dev.monogres.monobot.config.output;

import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.LinkedHashMap;
import java.util.SequencedMap;

/// What one version carries besides its own string: the placeholders its `sources` block reads and
/// cannot spell on its own, and the digest of the archive they name.
///
/// `sha256` is written last, after whatever the templates owe. The reader materializes the version
/// context before the source properties, so the order does not change which archive is named; it
/// is the order the catalog is written in, and the document has to come back byte for byte.
///
/// A string map rather than named fields, because what a version owes is decided by the templates
/// rather than by this: `upstream_version` for hll, `tag` for postgres, `tag` and `tag_dir` for
/// age, a `commit` where there is no tag at all.
@RegisterForReflection
public class VersionContext extends LinkedHashMap<String, String> {

  private static final long serialVersionUID = 1L;

  public static final String SHA256 = "sha256";

  public VersionContext() {}

  public VersionContext(SequencedMap<String, String> derived, String sha256) {
    putAll(derived);
    put(SHA256, sha256);
  }

  public String sha256() {
    return get(SHA256);
  }

  /// The context without the digest, which is what a `monobot.json` pins and what materializing a
  /// source block reads.
  public SequencedMap<String, String> derived() {
    var derived = new LinkedHashMap<>(this);
    derived.remove(SHA256);

    return derived;
  }
}
