"""
Stable fingerprint of a module-extension tag's attribute configuration.

Used by extension implementations to:

  - Detect real conflicts when the same `name` is declared with different
    configurations across modules (vs. identical re-declarations, which are
    benign and dedup naturally).
  - Build content-keyed dedup buckets when several tags should share a
    single materialized repo (omit `name` from the key so the bucket is keyed by
    configuration, not by tag name).

`hashed = False` (the default) yields a readable `tag-attr=value|...` form for
surfacing in error messages or debugging dedup decisions; pass `hashed = True`
for a short, target-name-safe content hash.
"""

load("//common:stable_key.bzl", "stable_key")

def tag_key(tag, exclude = [], hashed = False):
    """Stable fingerprint of a tag's attributes.

    Iterates `dir(tag)` and joins `attr=value` pairs for every attr not in
    `exclude` through `stable_key`. Same inputs produce the same key; any
    attribute difference (or a different exclude set) produces a different key.

    Args:
        tag: A module-extension tag value (from `module.tags.<class>`).
        exclude: Attribute names to omit from the fingerprint. Pass `["name"]`
            to bucket tags by configuration regardless of their `name` attr.
        hashed: When `False` (default), returns the readable
            `tag-attr=value|...` form. When `True`, returns the short hashed
            `tag-<h1>-<h2>-<n>` form from `stable_key`.

    Returns:
        A stable fingerprint string.
    """
    return stable_key(
        [
            "%s=%s" % (attr, getattr(tag, attr))
            for attr in dir(tag)
            if attr not in exclude
        ],
        prefix = "tag",
        hashed = hashed,
    )
