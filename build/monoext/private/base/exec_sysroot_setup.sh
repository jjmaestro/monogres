#!/bin/sh
# shellcheck disable=SC2154,SC2250
# Action-time setup of the EXEC-host-arch per-PG sysroot for cross-builds.
#
# The TARGET per-PG sysroot (extracted by `sysroot_setup.sh` to
# `$EXT_BUILD_ROOT/sysroot`) carries libs and headers compiled for the
# `--platforms` arch. Under cross-compile (host=amd64, target=arm64) the
# build-machine tools meson invokes during configure (msgfmt for NLS, etc.)
# need EXEC-host-arch binaries; the TARGET tree's `usr/bin/*` are aarch64
# ELFs that ld.so refuses to load on amd64.
#
# This script extracts the EXEC-arch sysroot tar (resolved via `exec_files`
# wrapping `:sysroot_tar` with `cfg = "exec"`) to a sibling
# `$EXT_BUILD_ROOT/exec_sysroot` tree. For NATIVE builds (host == target)
# the two tars are the same file and a ~1GB second extraction would be
# wasteful, so the script symlinks `exec_sysroot -> sysroot` instead.
#
# Inputs (`$(execpath ...)` substituted by rules_foreign_cc, all absolute
# inside the action sandbox):
#   $1  Target per-PG sysroot tar (TARGET arch, the one extracted to
#       `$EXT_BUILD_ROOT/sysroot` by `sysroot_setup.sh`).
#   $2  Exec per-PG sysroot tar (EXEC arch, resolved via `cfg = "exec"`).
#   $3  Hermetic `bsdtar` binary (same family as the TARGET extraction).
#
# For cross builds it also bridges the extracted tree's libs into the
# chroot's standard lib paths (as `sysroot_setup.sh` does for the TARGET
# tree), without which the EXEC-arch tools it just unpacked have neither
# their NEEDED .so nor glibc's `gconv/` modules on any path they look at.
#
# Output:
#   Prints `$EXT_BUILD_ROOT/exec_sysroot` (absolute). Caller assigns this
#   to `EXEC_SYSROOT_DIR`. Action consumers prepend its `usr/bin` to
#   `PATH` so meson's `find_program(..., native: true)` resolves
#   build-machine tools before falling through to TARGET-arch bins.
set -eu

if [ $# -ne 3 ]; then
    echo "usage: $0 <target-tar-abs> <exec-tar-abs> <bsdtar-abs>" >&2
    exit 2
fi

target_tar=$1
exec_tar=$2
bsdtar_abs=$3

EXEC_SR=${EXT_BUILD_ROOT}/exec_sysroot

# `realpath` canonicalizes through any symlink hops; for native builds the
# bzlmod-canonical paths of `target_tar` and `exec_tar` resolve to the same
# file on disk (Bazel deduplicates identical `:sysroot_tar` references) so
# the comparison succeeds and we avoid the 2nd extraction.
target_tar_real=$(realpath "$target_tar")
exec_tar_real=$(realpath "$exec_tar")
if [ "$target_tar_real" = "$exec_tar_real" ]; then
    # Native build: point EXEC_SYSROOT_DIR at the already-extracted target
    # tree. `ln -sfn`: force-overwrite, treat dir target as a file (no
    # follow-into-dir-and-create-link-inside trap on rerun).
    ln -sfn "${EXT_BUILD_ROOT}/sysroot" "$EXEC_SR"
else
    # Cross build: tars differ; extract the exec tar to its own dir.
    mkdir -p "$EXEC_SR"
    "$bsdtar_abs" -xf "$exec_tar" -C "$EXEC_SR"

    # Bridge the EXEC tree's libs into the chroot's standard
    # `/lib/<multiarch>/` + `/usr/lib/<multiarch>/` paths, the same way
    # `sysroot_setup.sh` does for the TARGET tree. The native branch above
    # inherits that tree's bridge for free; a cross build extracts a second
    # tree that nothing has bridged, so its EXEC-arch tools run with an
    # ld.so (and a glibc) that cannot see anything under it.
    #
    # This is not only about NEEDED .so resolution: the bridge mirrors whole
    # directories, which is what puts `gconv/` on glibc's compiled-in
    # `/usr/lib/<multiarch>/gconv` search path. Without it iconv() has no
    # charset modules at all, and the first tool to notice is `msgfmt`,
    # which fails every non-UTF-8 catalog with "Cannot convert from
    # ISO-8859-1 to UTF-8" and takes Postgres's whole NLS build down with it.
    #
    # The two bridges cannot collide: they are keyed by multiarch triplet,
    # and under cross the EXEC and TARGET triplets differ by definition.
    #
    # The triplet is derived from the extracted tree (its only `*-linux-gnu`
    # child of `usr/lib/`), as in `sysroot_setup.sh`: the tree is the
    # authority on the arch it carries.
    exec_multiarch=
    for d in "$EXEC_SR/usr/lib/"*-linux-gnu; do
        base=$(basename "$d")
        case "$base" in
            x86_64-linux-gnu|aarch64-linux-gnu) exec_multiarch=$base ;;
            *) ;;
        esac
    done
    if [ -z "$exec_multiarch" ]; then
        echo "no multiarch dir found in $EXEC_SR/usr/lib" >&2
        exit 1
    fi

    # Best-effort as in `sysroot_setup.sh`: absolute dst, skip a
    # pre-existing entry so a bind-mount wins, and suppress EROFS on a
    # read-only parent instead of taking the build down.
    for srcdir in \
        "$EXEC_SR/lib/$exec_multiarch" \
        "$EXEC_SR/usr/lib/$exec_multiarch"; do
        [ -d "$srcdir" ] || continue
        dstdir=${srcdir#"$EXEC_SR"}
        mkdir -p "$dstdir" 2>/dev/null || continue
        for src in "$srcdir"/*; do
            [ -e "$src" ] || continue
            dst="$dstdir/$(basename "$src")"
            [ -e "$dst" ] && continue
            ln -s "$src" "$dst" 2>/dev/null || true
        done
    done
fi

echo "$EXEC_SR"
