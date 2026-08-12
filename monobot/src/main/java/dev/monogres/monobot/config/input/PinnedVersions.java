package dev.monogres.monobot.config.input;

import com.fasterxml.jackson.core.JsonGenerator;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationContext;
import com.fasterxml.jackson.databind.JsonDeserializer;
import com.fasterxml.jackson.databind.JsonMappingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.JsonSerializer;
import com.fasterxml.jackson.databind.SerializerProvider;
import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import dev.monogres.monobot.config.output.Version;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

/// The versions an entry pins, each with whatever its `sources` block owes it.
///
/// Written as a list where nothing is owed and as a map where something is, which is the shape of
/// the catalog: 47 of its 53 entries pin one version and most of them owe nothing at all.
///
/// ```json
/// "pin": ["0.8.2"]
/// "pin": { "18.1": {"tag": "REL_18_1"}, "18.0": {"tag": "REL_18_0"} }
/// ```
///
/// The order is the order they are written, and that is the order `repo.json` presents them in.
@JsonDeserialize(using = PinnedVersions.FromListOrMap.class)
@JsonSerialize(using = PinnedVersions.AsListOrMap.class)
@RegisterForReflection
public class PinnedVersions extends LinkedHashMap<Version, LinkedHashMap<String, String>> {

  private static final long serialVersionUID = 1L;

  /// Written back in whichever of the two shapes says the least: the list where no version owes
  /// its sources anything, and the map where any of them does. Round trips through
  /// [PinnedVersions.FromListOrMap], which is what `import` is checked by.
  @RegisterForReflection
  static final class AsListOrMap extends JsonSerializer<PinnedVersions> {
    @Override
    public void serialize(
        PinnedVersions pinned, JsonGenerator generator, SerializerProvider serializers)
        throws IOException {
      if (pinned.values().stream().allMatch(Map::isEmpty)) {
        generator.writeStartArray();
        for (var version : pinned.keySet()) {
          generator.writeString(version.version());
        }
        generator.writeEndArray();

        return;
      }

      generator.writeStartObject();
      for (var pin : pinned.entrySet()) {
        generator.writeObjectField(pin.getKey().version(), pin.getValue());
      }
      generator.writeEndObject();
    }
  }

  @RegisterForReflection
  static final class FromListOrMap extends JsonDeserializer<PinnedVersions> {
    private static final String NOT_A_PIN =
        "A pin is a list of versions or a map of version to the context its sources read";

    private static LinkedHashMap<String, String> contextOf(JsonNode declared) {
      var context = new LinkedHashMap<String, String>();
      if (!declared.isObject()) {
        throw new IllegalArgumentException(
            NOT_A_PIN + ", and this version maps to a " + declared.getNodeType());
      }
      declared
          .properties()
          .forEach(entry -> context.put(entry.getKey(), entry.getValue().asText()));

      return context;
    }

    @Override
    public PinnedVersions deserialize(JsonParser parser, DeserializationContext context)
        throws IOException {
      var pinned = new PinnedVersions();
      JsonNode declared = parser.readValueAsTree();

      try {
        if (declared.isArray()) {
          declared.forEach(
              version -> pinned.put(new Version(version.asText()), new LinkedHashMap<>()));
        } else if (declared.isObject()) {
          declared
              .properties()
              .forEach(
                  entry -> pinned.put(new Version(entry.getKey()), contextOf(entry.getValue())));
        } else {
          throw new IllegalArgumentException(NOT_A_PIN + ", not a " + declared.getNodeType());
        }
      } catch (IllegalArgumentException e) {
        throw JsonMappingException.from(parser, e.getMessage(), e);
      }

      return pinned;
    }
  }
}
