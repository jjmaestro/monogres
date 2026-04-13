"""
Extension version × base version compatibility.

Wraps `//monoext/private/base:compat.bzl::is_compatible_with` with the
extension-specific lookup (reads `compatible_with` map from an extension's
`repo.json` metadata) and debug formatting.
"""

load("//monoext/private/base:compat.bzl", "is_compatible_with")

def is_compatible(name, version, base_version, metadata = None, debug = False):
    """
    Checks if a given extension version is compatible with a base version.

    Args:
        name (str): The name of the extension.
        version (str): The version of the extension being checked.
        base_version (str): The base version to check against (the constraint
            scheme is currently PGVER, since the base flavor is PostgreSQL).
        metadata (dict, optional): Optional metadata with `compatible_with`
            mapping.
        debug (bool): If True, prints a debug message on incompatibility.

    Returns:
        `True` if the extension version is compatible with the given base
        version, `False` otherwise.
    """
    metadata = metadata or {}
    cspec = metadata.get("compatible_with", {}).get(version, "*")

    debug_prefix = "Extension %r v%s" % (name, version) if debug else None

    return is_compatible_with(base_version, cspec, debug_prefix)
