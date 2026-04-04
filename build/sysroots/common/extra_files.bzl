"""
Tier-2 injection: drop per-tag files into the sysroot tree at repo-rule time.

After Tier-1 normalizations have rewritten symlinks and ld scripts, the
`extra_files` dict on each `sysroots.<pkg_manager>(...)` tag is applied. For
each `source_label -> in_sysroot_path` pair the source label's content is read
with `rctx.read(rctx.path(...))` and written at `<sysroot_dir>/<path>` with the
executable bit set.

This is how the per-arch clang wrapper lands at
`@<hub>//<distro>/<version>/<arch>/usr/lib/llvm-<V>/bin/clang` without
`//sysroots` knowing anything about LLVM. The toolchain owns the wrapper script
and the `MODULE.bazel` author wires it in via `extra_files`.

The `{arch}` placeholder in the path is substituted at write time so the same
dict entry can target each arch with one declaration. The dict is applied AFTER
Tier-1 so users can override normalized state if they really need to.
"""

def _resolve_target_path(sysroot_dir, arch, path):
    """Substitute `{arch}` in `path` and join with `sysroot_dir`.

    Args:
        sysroot_dir: Sysroot root directory.
        arch: Arch the sysroot is being materialized for (`amd64`, `arm64`).
        path: In-sysroot path with optional `{arch}` placeholder.

    Returns:
        The absolute (or rctx-relative) path inside the sysroot where the extra
        file should land.
    """
    return "%s/%s" % (sysroot_dir, path.replace("{arch}", arch))

def _apply(rctx, sysroot_dir, arch, extra_files):
    """Apply a tag's `extra_files` map into one arch's sysroot.

    Args:
        rctx: A `repository_ctx`.
        sysroot_dir: Sysroot root for this arch (string or `Path`).
        arch: Arch name (`amd64`, `arm64`).
        extra_files: `{Label-or-string: in_sysroot_path}` dict from the tag.
            Each `in_sysroot_path` may contain a `{arch}` placeholder.
    """
    sr = str(sysroot_dir)
    for label, path in extra_files.items():
        target = _resolve_target_path(sr, arch, path)
        rctx.file(
            target,
            rctx.read(rctx.path(label)),
            executable = True,
        )

extra_files = struct(
    resolve_target_path = _resolve_target_path,
    apply = _apply,
)
