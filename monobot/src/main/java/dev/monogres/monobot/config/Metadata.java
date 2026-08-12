package dev.monogres.monobot.config;

import com.fasterxml.jackson.databind.JsonNode;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.util.LinkedHashMap;

/// The `metadata` block, carried from `monobot.json` to `repo.json` exactly as it was written.
///
/// None of it is monobot's to derive. Which Postgres majors an extension is compatible with, which
/// patches apply to which versions, what a test suite is called, which Debian packages a build
/// needs: every one of those is a decision, and monobot holds the decisions rather than makes
/// them.
///
/// Trees rather than a model, and insertion-ordered rather than sorted, so what comes out is what
/// went in. There is no one order to impose: `compatible_with` is keyed newest version first while
/// `deps.buildtime.debian` reads `12` then `13`, and both are right.
@RegisterForReflection
public class Metadata extends LinkedHashMap<String, JsonNode> {

  private static final long serialVersionUID = 1L;
}
