# shellcheck shell=sh
# shellcheck disable=SC2250
# Shared sysroot/closure population mechanics.
#
# Sourced by both the build-time setup (`base/sysroot_setup.sh`, which layers
# perl Config + clang-wrapper post-processing on top) and the test-time closure
# populator (`test/closure_setup.sh`, which layers multiple tars + a run mode).
# The functions here manipulate an extracted sysroot tree: extract sysroot tars,
# derive the Debian multiarch triplet from the tree, symlink the multiarch libs
# into the hermetic chroot's standard lib paths (so ld.so's default search
# resolves NEEDED .so with no LD_LIBRARY_PATH), and remap baked absolute paths
# in the tree's scripts.
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
# LD_LIBRARY_PATH. Three bridges via `_bridge_libs`: the multiarch subdirs
# verbatim, any `.so*` sitting directly in lib/ (some Debian libs are still
# non-multiarch, e.g. libarmadillo14), and versioned `lib*.so.*` from immediate
# subdirs of the multiarch dir.
symlink_chroot_libs() {
    _root=$1
    _multiarch=$2

    # Standard multiarch subdirs: mirror every entry into the chroot's
    # /lib/<triplet> + /usr/lib/<triplet>.
    for _dir in "$_root/lib/$_multiarch" "$_root/usr/lib/$_multiarch"; do
        [ -d "$_dir" ] || continue
        _bridge_libs "${_dir#"$_root"}" "" "$_dir"/*
    done

    # Non-multiarch libs sitting directly in lib/ (some Debian libs are still
    # non-multiarch, e.g. libarmadillo14): bridge the `.so*` files into the
    # multiarch dir.
    for _dir in "$_root/lib" "$_root/usr/lib"; do
        _bridge_libs "${_dir#"$_root"}/$_multiarch" files "$_dir"/*.so*
    done

    # Debian alternatives-managed libs (e.g. BLAS/LAPACK) sit in a subdir of the
    # multiarch dir (blas/libblas.so.3); the SONAME symlink in the multiarch dir
    # is normally created by a postinst update-alternatives call, absent from a
    # data.tar-only closure. Bridge versioned `lib*.so.*` from immediate subdirs
    # up to the multiarch dir so ld.so resolves the SONAME. (Plugin subdirs like
    # gconv/ or security/ hold path-loaded modules, not `lib*.so.*`, so are left.)
    for _dir in "$_root/lib/$_multiarch" "$_root/usr/lib/$_multiarch"; do
        [ -d "$_dir" ] || continue
        _bridge_libs "${_dir#"$_root"}" files "$_dir"/*/lib*.so.*
    done
}

# remap_paths <root> <pattern> <from> <to>
# Replace <from> with <to> in each script matching <root>/usr/bin/<pattern>. A
# script may bake absolute paths a consumer reads verbatim rather than through a
# sysroot search (a `*-config` tool's `--cflags` / `--libs`, ...); rewriting
# them re-roots those paths into the extracted tree. <pattern> is a basename or
# POSIX glob; <from> / <to> are literal path-like strings (no `|`, the sed
# delimiter). The interpreter (`#!`) line is left as-is, and non-script (ELF)
# files are skipped via the `#!` check, so an ELF tool is left intact. The
# extracted tree is writable, so the sed runs in place.
remap_paths() {
    _root=$1
    _pattern=$2
    _from=$3
    _to=$4
    # shellcheck disable=SC2086 # pattern is globbed on purpose
    for _f in "$_root"/usr/bin/$_pattern; do
        [ -f "$_f" ] || continue
        _magic=$(head -c 2 "$_f" 2>/dev/null) || _magic=
        [ "$_magic" = "#!" ] || continue
        sed -i "1!s|$_from|$_to|g" "$_f"
    done
}
