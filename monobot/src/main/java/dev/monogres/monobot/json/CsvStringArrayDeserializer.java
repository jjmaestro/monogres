package dev.monogres.monobot.json;

import com.fasterxml.jackson.core.JacksonException;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationContext;
import com.fasterxml.jackson.databind.JsonDeserializer;
import java.io.IOException;

public class CsvStringArrayDeserializer extends JsonDeserializer<String[]> {
  @Override
  public String[] deserialize(JsonParser p, DeserializationContext ctxt)
      throws IOException, JacksonException {
    var csv = p.getText();

    // Stripped first, because splitting on the commas takes the whitespace around each of them and
    // leaves the whitespace at the two ends of the value: the first and last names would keep it,
    // and a name with a space in front of it is a different name.
    if (csv == null || csv.strip().isEmpty()) {
      return null;
    }

    return csv.strip().split("\\s*,\\s*");
  }
}
