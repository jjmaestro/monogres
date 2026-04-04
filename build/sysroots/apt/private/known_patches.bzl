"""
Known-package patches applied as part of Tier-1 sysroot normalization.

Some Debian packages bake absolute system paths into config files that are read
at consumer time; in a hermetic build those paths point at nothing (empty
chroot) or at the host (non-hermetic); neither matches the sysroot.
`KNOWN_PATCHES` maps a Debian package name to a patcher function. The repo rule
iterates the resolved package list and calls each unique patcher once per arch
sysroot, AFTER `normalize.relativize_symlinks` and
`normalize.rewrite_ld_scripts`.

Empty by default. Add an entry when a new package surfaces a path-baking issue
that's stable enough to fix at repo-rule time.

NOTE: any patcher added here MUST bake paths that are valid in the read-only
`@hub` repo (sysroot-relative, or paths derived from `rctx.path` that the
consuming action can still reach). Patches that need an action-time-only
absolute path have to live on the consumer side, not here.
"""

KNOWN_PATCHES = {}

def _apply(rctx, sysroot_dir, packages):
    """Apply every patcher that matches a resolved package, deduped.

    Args:
        rctx: A `repository_ctx`.
        sysroot_dir: Sysroot root.
        packages: List of resolved package dicts (each with `name`).
    """
    seen = {}
    for pkg in packages:
        name = pkg["name"]
        fn = KNOWN_PATCHES.get(name)
        if fn == None:
            continue
        key = repr(fn)
        if key in seen:
            continue
        seen[key] = True
        fn(rctx, sysroot_dir)

known_patches = struct(
    KNOWN_PATCHES = KNOWN_PATCHES,
    apply = _apply,
)
