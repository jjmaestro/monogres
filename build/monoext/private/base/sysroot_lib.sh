# shellcheck shell=sh
# shellcheck disable=SC2250
# Shared sysroot/closure population mechanics.
#
# Sourced by both the build-time setup (`base/sysroot_setup.sh`, which layers
# perl Config + clang-wrapper post-processing on top) and the test-time closure
# populator (`test/closure_setup.sh`, which layers multiple tars + a run mode).
# These three functions are the population mechanics both share: extract sysroot
# tars, derive the Debian multiarch triplet from the tree, and symlink the
# multiarch libs into the hermetic chroot's standard lib paths so ld.so's
# default search resolves NEEDED .so with no LD_LIBRARY_PATH.
#
# POSIX sh (the build action runs under `sh`). Functions prefix their working
# variables with `_` so they do not clobber the sourcing script's variables.

# extract_tars <bsdtar> <dest> [<tar> ...]
# Extract each tar into <dest> in order (later wins on overlap). Creates <dest>
# if absent; skips empty tar arguments (a flavor may pass an unset optional
# closure).
extract_tars() {
    _bsdtar=$1
    _dest=$2
    shift 2
    mkdir -p "$_dest"
    for _tar in "$@"; do
        [ -n "$_tar" ] || continue
        "$_bsdtar" -xf "$_tar" -C "$_dest"
    done
}

# derive_multiarch <root>
# Print the Debian multiarch triplet (x86_64-linux-gnu / aarch64-linux-gnu)
# found under <root>/usr/lib or <root>/lib. Derived from the extracted tree,
# NOT `uname -m`, so it holds under cross-compilation (the sysroot carries the
# TARGET arch while uname reports the HOST). Returns 1 with a message on stderr
# when no multiarch dir is present.
derive_multiarch() {
    _root=$1
    _multiarch=
    for _dir in "$_root"/usr/lib/*-linux-gnu "$_root"/lib/*-linux-gnu; do
        [ -d "$_dir" ] && _multiarch=$(basename "$_dir")
    done
    if [ -z "$_multiarch" ]; then
        echo "sysroot_lib: no multiarch dir under $_root/{usr/,}lib" >&2
        return 1
    fi
    printf '%s\n' "$_multiarch"
}

# _bridge_libs <dstdir> <files_only> <src>...
# Symlink each existing <src> into <dstdir>. With a non-empty <files_only>, skip
# directories and link only regular library files. Absolute dst; skip any
# pre-existing dst (let a bind-mount win); create <dstdir> as needed; suppress
# EROFS on a read-only parent and keep going.
_bridge_libs() {
    _dstdir=$1
    _files_only=$2
    shift 2
    [ -d "$_dstdir" ] || mkdir -p "$_dstdir" 2>/dev/null || return 0
    for _src in "$@"; do
        [ -e "$_src" ] || continue
        [ -n "$_files_only" ] && [ -d "$_src" ] && continue
        _dst="$_dstdir/$(basename "$_src")"
        [ -e "$_dst" ] && continue
        ln -s "$_src" "$_dst" 2>/dev/null || true
    done
}

# symlink_chroot_libs <root> <multiarch>
# Symlink <root>'s libs into the chroot's standard /lib/<triplet> +
# /usr/lib/<triplet> so ld.so's default search resolves NEEDED .so with no
# LD_LIBRARY_PATH, via `_bridge_libs`.
symlink_chroot_libs() {
    _root=$1
    _multiarch=$2

    # Standard multiarch subdirs: mirror every entry into the chroot's
    # /lib/<triplet> + /usr/lib/<triplet>.
    for _dir in "$_root/lib/$_multiarch" "$_root/usr/lib/$_multiarch"; do
        [ -d "$_dir" ] || continue
        _bridge_libs "${_dir#"$_root"}" "" "$_dir"/*
    done
}
