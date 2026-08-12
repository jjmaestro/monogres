package dev.monogres.monobot.fetch;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import io.quarkus.runtime.annotations.RegisterForReflection;

/// What one run learned about one archive, written beside it in the cache.
///
/// This is what a later run answers from instead of asking the source again. `url` says which
/// archive the file is, since a version whose template changed names different bytes under the same
/// key. `size` is the cheapest check that the file is still whole and `sha256` the exact one.
/// `etag` and `last_modified` are the source's own validators, echoed back on a refresh so an
/// archive that has not changed costs a 304 rather than the whole file again; a source that offers
/// neither leaves both out.
///
/// An `etag` reads as `"\"3f4a...\""` and that is not an escaping mistake. An entity-tag is quoted
/// by definition, RFC 9110 opaque-tag being `DQUOTE *etagc DQUOTE`, so the quotes are inside the
/// value the source sent and `If-None-Match` has to carry them back. Handing back the digits alone
/// is a request no source recognizes, which answers 200 and re-sends the whole archive.
///
/// `fetched_at` is when these bytes arrived. It answers nothing monobot asks and is here for
/// whoever is reading the cache to work out what happened.
@RegisterForReflection
@JsonPropertyOrder({"url", "sha256", "size", "last_modified", "etag", "fetched_at"})
public record ArchiveRecord(
    String url,
    String sha256,
    long size,
    @JsonProperty("last_modified") String lastModified,
    String etag,
    @JsonProperty("fetched_at") String fetchedAt) {}
