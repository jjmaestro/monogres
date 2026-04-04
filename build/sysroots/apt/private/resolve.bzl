"""
Thin wrapper around `//apt/private:apt_resolve.bzl::resolve` for the sysroot
context: takes a parsed-and-merged manifest struct + a Debian snapshot, returns
the resolver's `(lockfile, package_name_map)` tuple.
"""

# buildifier: disable=bzl-visibility
load("//apt/private:apt_resolve.bzl", _apt_resolve = "resolve")

def _resolve_sysroot(ctx, name, manifest, snapshot):
    """Resolve a sysroot manifest against a Debian snapshot.

    Args:
        ctx: A module extension context.
        name: Internal resolver-repo name (used for error messages).
        manifest: Struct from `//apt/private:manifest.bzl::resolve_attrs`,
            carrying the merged `archs` + `packages`.
        snapshot: Debian snapshot timestamp string.

    Returns:
        Tuple `(lockfile, package_name_map)`. See `apt_resolve.resolve`.
    """
    return _apt_resolve(
        ctx,
        name,
        manifest.archs,
        manifest.packages,
        snapshot,
    )

resolve = struct(
    sysroot = _resolve_sysroot,
)
