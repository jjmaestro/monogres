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

    if (csv == null || csv.isEmpty()) {
      return null;
    }

    return csv.split("\\s*,\\s*");
  }
}
