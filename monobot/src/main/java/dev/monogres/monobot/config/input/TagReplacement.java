package dev.monogres.monobot.config.input;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.DeserializationContext;
import com.fasterxml.jackson.databind.JsonDeserializer;
import com.fasterxml.jackson.databind.JsonMappingException;
import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import io.quarkus.runtime.annotations.RegisterForReflection;
import java.io.IOException;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.regex.Pattern;

/// One rule for reading a version out of a tag name, written as the pair `[regex, replacement]`.
@JsonDeserialize(using = TagReplacement.FromPair.class)
@RegisterForReflection
public record TagReplacement(Pattern regex, String replacement) {
  Optional<String> appliedTo(String tagName) {
    var matcher = regex.matcher(tagName);

    return matcher.matches() ? Optional.of(matcher.replaceFirst(replacement)) : Optional.empty();
  }

  @RegisterForReflection
  static final class FromPair extends JsonDeserializer<TagReplacement> {
    private static final String NOT_A_PAIR = "A replace rule is a [regex, replacement] pair";
    private static final TypeReference<List<String>> PAIR = new TypeReference<>() {};

    @Override
    public TagReplacement deserialize(JsonParser parser, DeserializationContext context)
        throws IOException {
      try {
        if (!parser.isExpectedStartArrayToken()) {
          throw new IllegalArgumentException(NOT_A_PAIR + ", not a " + parser.currentToken());
        }

        List<String> rule = parser.readValueAs(PAIR);
        // Iterating instead of `contains(null)` because an immutable list would throw
        if (rule.size() != 2 || rule.stream().anyMatch(Objects::isNull)) {
          throw new IllegalArgumentException(NOT_A_PAIR + ", and this is not one: " + rule);
        }

        return new TagReplacement(Pattern.compile(rule.get(0)), rule.get(1));
      } catch (IllegalArgumentException e) {
        throw JsonMappingException.from(parser, e.getMessage(), e);
      }
    }
  }
}
