"""
Alias repository rule for deduped `sysroots.apt(...)` tags.

When multiple tags resolve to the same `_dedup_key` (every attr except `name`)
only one canonical hub is materialized via `hub_repo`. The remaining tags become
`alias_hub` instances: their on-disk repo contains per-arch **directory
symlinks** pointing at the canonical hub's actual extracted tree.

The symlink approach (rather than `alias()` BUILD targets) is required by
filegroup-mode consumers like [`toolchains_llvm`]'s `llvm.sysroot(label=...)`,
which records the label's package path verbatim as `--sysroot=` and needs real
files at that on-disk location. Symlinks let both
`@canonical//<distro>/<v>/<arch>:sysroot` and
`@alias//<distro>/<v>/<arch>:sysroot` work. The dedup is invisible to consumers;
only the disk footprint shrinks.

The lock subpackage gets symlinked too when the canonical has one, so `bazel run
@alias//<v>/lock:update` works from any tag in the dedup group.

[`toolchains_llvm`]: https://github.com/bazel-contrib/toolchains_llvm
"""

load(
    "//common:codegen.bzl",
    "distro_root_build",
    "hub_root_build",
    "version_root_build",
)

def _alias_hub_impl(rctx):
    distros = json.decode(rctx.attr.distros_json)

    # Canonical's repo root via the sentinel BUILD.bazel label. The `attr.label`
    # also forces Bazel to materialize the canonical hub before this alias rule
    # runs, so the symlink targets exist on disk.
    canonical_root = rctx.path(rctx.attr.canonical_build).dirname

    rctx.file("BUILD.bazel", hub_root_build())

    for distro, versions in distros.items():
        rctx.file("%s/BUILD.bazel" % distro, distro_root_build())

        for version, info in versions.items():
            version_dir = "%s/%s" % (distro, version)
            rctx.file("%s/BUILD.bazel" % version_dir, version_root_build())

            for arch in info["archs"]:
                arch_subdir = "%s/%s" % (version_dir, arch)
                rctx.symlink(
                    "%s/%s" % (canonical_root, arch_subdir),
                    arch_subdir,
                )

            # Lock subpackage: symlink only when the canonical has one. Empty
            # `lock_json` (or missing key) means the canonical skipped lock
            # emission; the alias does the same.
            if info.get("lock_json"):
                rctx.symlink(
                    "%s/%s/lock" % (canonical_root, version_dir),
                    "%s/lock" % version_dir,
                )

alias_hub = repository_rule(
    implementation = _alias_hub_impl,
    attrs = dict(
        canonical_build = attr.label(
            mandatory = True,
            doc = (
                "Label of the canonical hub's root `BUILD.bazel`. Establishes " +
                "a repo-rule ordering dependency (Bazel materializes the " +
                "canonical before this alias) and anchors the per-arch symlink " +
                "targets."
            ),
        ),
        distros_json = attr.string(
            mandatory = True,
            doc = (
                "JSON-encoded `{distro: {version: {archs: {...}, lock_json: " +
                "str, ...}}}`. Mirrors `hub_repo`'s homonymous attr; only the " +
                "`archs` keys and `lock_json` presence are read here (the " +
                "canonical owns the actual content)."
            ),
        ),
    ),
)
