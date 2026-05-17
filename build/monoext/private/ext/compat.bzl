"""
Extension version × base version compatibility.

Wraps `//monoext/private/base:compat.bzl::is_compatible_with` with the
extension-specific lookup (reads `compatible_with` map from an extension's
`repo.json` metadata) and debug formatting.
"""

load("//monoext/private/base:compat.bzl", "is_compatible_with")

def is_compatible(name, version, flavor, base_version, metadata = None, debug = False):
    """
    Checks if a given extension version is compatible with a base version.

    Args:
        name (str): The name of the extension.
        version (str): The version of the extension being checked.
        flavor (str): Base flavor identity (e.g. "postgres", "ivorysql").
        base_version (str): The base version to check against.
        metadata (dict, optional): Optional metadata with `compatible_with`
            mapping.
        debug (bool): If True, prints a debug message on incompatibility.

    Returns:
        `True` if the extension version is compatible with the given base
        version, `False` otherwise.
    """
    metadata = metadata or {}
    compat = metadata.get("compatible_with")

    if compat == None:
        cspec = "*"  # whole-key absent → wildcard for all flavors
    else:
        flavor_compat = compat.get(flavor)
        if flavor_compat == None:
            return False  # explicit opt-in: missing flavor key → not compatible
        cspec = flavor_compat.get(version)
        if cspec == None:
            return False  # ext_v not declared for this flavor

    debug_prefix = (
        "Extension %r v%s [flavor=%s]" % (name, version, flavor) if debug else None
    )

    return is_compatible_with(base_version, cspec, debug_prefix)
