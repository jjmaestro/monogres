package dev.monogres.monobot.config.output;

import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.LinkedHashMap;

/// The versions of one entry, in the order they are written.
///
/// Written rather than sorted, because the catalog is not sorted one way. Newest first is what
/// almost every entry carries and what a discovered version is inserted as, but babelfish reads
/// `4.0` then `5.1` and a comparator would turn that around. The order is the document's to state
/// and monobot's to keep.
@RegisterForReflection
public class Versions extends LinkedHashMap<Version, VersionContext> {

  private static final long serialVersionUID = 1L;
}
