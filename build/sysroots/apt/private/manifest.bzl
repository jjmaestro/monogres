"""
Manifest parsing + tag-attr merging for `sysroots.apt(...)`.

A `sysroots.apt(...)` tag may provide its `{distro, version, archs, packages,
snapshot}` either as explicit attrs, as a JSON `manifest` label, or a mix.
`parse_manifest` decodes the JSON; `resolve_attrs` merges the two with
explicit-tag-attr-wins semantics and validates that the required fields end up
populated.

Manifest schema (`version` = 1):

    {
        "version": 1, "distro": "debian", "distro_version": "12", "snapshot":
        "20250113T000000Z", "archs": ["amd64", "arm64"], "packages":
        ["libc6-dev", "..."]
    }
"""

load("//common:archs.bzl", _DEFAULT_ARCHS = "ARCHS")

MANIFEST_VERSION = 1

def _parse_manifest(manifest_json):
    """Decode a manifest JSON string.

    Validates the version field; does not require any other field. Required
    fields are checked after merging with the tag in `resolve_attrs`.

    Args:
        manifest_json: A JSON string (e.g. from `ctx.read(tag.manifest)`).

    Returns:
        A struct with `distro`, `version`, `archs`, `packages`, `snapshot` (each
        may be `None` if absent from the JSON).
    """
    m = json.decode(manifest_json)

    version = m.get("version", 0)
    if version != MANIFEST_VERSION:
        fail("sysroots.apt: manifest version %d, expected %d" % (
            version,
            MANIFEST_VERSION,
        ))

    return struct(
        distro = m.get("distro"),
        version = m.get("distro_version"),
        archs = m.get("archs"),
        packages = m.get("packages"),
        snapshot = m.get("snapshot"),
    )

def _resolve_attrs(name, distro, version, archs, packages, snapshot, manifest):
    """Merge tag attrs with manifest fields, explicit-tag-attr-wins.

    Validates that `distro`, `version`, `packages`, `snapshot` end up populated.
    Defaults `archs` to `//common:archs.bzl::ARCHS` if both tag and manifest
    leave it empty.

    Args:
        name: The tag's `name` attr (used in error messages).
        distro: The tag's `distro` attr value (string, may be `""`).
        version: The tag's `version` attr value (string, may be `""`).
        archs: The tag's `archs` attr value (list, may be `[]`).
        packages: The tag's `packages` attr value (list, may be `[]`).
        snapshot: The tag's `snapshot` attr value (string, may be `""`).
        manifest: A struct from `parse_manifest`, or `None` if no manifest was
            provided.

    Returns:
        A struct `(name, distro, version, archs, packages, snapshot)` with
        `archs` sorted and `packages` sorted+deduplicated.
    """
    resolved_distro = distro or (manifest.distro if manifest else "")
    if not resolved_distro:
        fail((
            "sysroots.apt(name=%r): 'distro' is required " +
            "(set tag attr or include in manifest)"
        ) % name)

    resolved_version = version or (manifest.version if manifest else "")
    if not resolved_version:
        fail((
            "sysroots.apt(name=%r): 'version' is required " +
            "(set tag attr or include in manifest)"
        ) % name)

    if archs:
        resolved_archs = list(archs)
    elif manifest and manifest.archs:
        resolved_archs = list(manifest.archs)
    else:
        resolved_archs = list(_DEFAULT_ARCHS)

    if packages:
        resolved_packages = list(packages)
    elif manifest and manifest.packages:
        resolved_packages = list(manifest.packages)
    else:
        fail((
            "sysroots.apt(name=%r): 'packages' is required " +
            "(set tag attr or include in manifest)"
        ) % name)

    resolved_snapshot = snapshot or (manifest.snapshot if manifest else "")
    if not resolved_snapshot:
        fail((
            "sysroots.apt(name=%r): 'snapshot' is required " +
            "(set tag attr or include in manifest)"
        ) % name)

    return struct(
        name = name,
        distro = resolved_distro,
        version = resolved_version,
        archs = sorted(resolved_archs),
        packages = sorted({p: True for p in resolved_packages}.keys()),
        snapshot = resolved_snapshot,
    )

manifest = struct(
    MANIFEST_VERSION = MANIFEST_VERSION,
    parse = _parse_manifest,
    resolve_attrs = _resolve_attrs,
)
