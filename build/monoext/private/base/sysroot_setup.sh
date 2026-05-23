#!/bin/sh
# shellcheck disable=SC2154,SC2250
# Action-time setup of the per-PG sysroot for `pg_build` / `pgxs_build`.
#
# Extraction, multiarch detection, and the chroot lib symlinks are delegated to
# the sibling `sysroot_lib.sh`; this script layers the build-only perl Config +
# clang-wrapper post-processing on top.
#
# Inputs (all come from `$(execpath ...)` substitutions, which
# `rules_foreign_cc` auto-prepends with `$EXT_BUILD_ROOT/` — see
# https://github.com/bazel-contrib/rules_foreign_cc/blob/0.12.0/foreign_cc/private/make_env_vars.bzl#L123-L124
# so the args land here as absolute paths inside the action sandbox):
#   $1  Absolute path of the per-PG sysroot tar.
#   $2  Absolute path of the @libc_sysroot clang wrapper.
#   $3  Absolute path of the hermetic `bsdtar` binary from
#       `@bsd_tar_toolchains_<host_arch>//:tar`. Same `bsdtar` family
#       that writes the archive in `sysroots/apt/private/repo.bzl`'s
#       `_make_sysroot_tar`, so the pax-format snapshot round-trips
#       end-to-end (symbolic links, long paths, uid/gid/mtime, and
#       pax extended attributes preserved verbatim).
#   $4  LLVM major-version digit (Debian package suffix) used to compose
#       the `usr/lib/llvm-N/bin/` install path the clang wrapper lands at.
#
# Side effects:
#   - Extracts the tar to `$EXT_BUILD_ROOT/sysroot/`. The tar carries the
#     full normalized payload (symlinks relativized, ld scripts
#     `=`-prefixed, extra_files injected) — all the Tier-1 work done at
#     `//sysroots/apt` repo-rule time.
#   - Symlinks the multiarch libperl.so into the perl/<ver>/CORE/ dir so
#     plperl's `cc.links(perl_alloc, ...)` probe resolves libperl (the
#     version dir is discovered from the tree, not pinned).
#   - Patches perl's `Config.pm` / `Config_heavy.pl` in place so the
#     plperl probe sees sysroot-rooted paths instead of host
#     `/usr/lib/...`. In tar mode the extracted tree is per-action and
#     writable, so the sed runs directly (vs. the pre-tar overlay design
#     that lived here for the filegroup-mode `@pgbuildtime` hub).
#   - Symlinks the @libc_sysroot clang wrapper at
#     `<sysroot>/usr/lib/llvm-14/bin/clang`. Meson canonicalizes the
#     symlink before baking `CLANG` into the installed `Makefile.global`,
#     so downstream PGXS extensions get a persistent
#     `/external/sysroots++sysroots+libc_sysroot/...` path that survives
#     sandbox teardowns.
#
# Output:
#   Prints `$EXT_BUILD_ROOT/sysroot` (absolute). Caller assigns this to
#   `SYSROOT_DIR`. rules_foreign_cc does NOT auto-prepend `$EXT_BUILD_ROOT/`
#   here (the printed path doesn't contain `external/`).
set -eu

if [ $# -ne 4 ]; then
    echo "usage: $0 <tar-abs> <wrapper-abs> <bsdtar-abs> <llvm-major>" >&2
    exit 2
fi

# Shared extract / multiarch / chroot-symlink mechanics, in a sibling lib (both
# this script and the lib are materialized into the action via build_data), so
# source it relative to $0.
# shellcheck disable=SC1091 source=sysroot_lib.sh
. "$(dirname "$0")/sysroot_lib.sh"

tar_abs=$1
wrapper_abs=$2
bsdtar_abs=$3
llvm_major=$4

SR=${EXT_BUILD_ROOT}/sysroot
extract_tars "$bsdtar_abs" "$SR" "$tar_abs"

# Bridge Debian's multiarch libperl layout to the Config_overrides shim's
# claimed `archlibexp` ($SR/usr/lib/<cpu>-linux-gnu/perl/<ver>). Debian's
# libperl-dev ships `libperl.so` at `$SR/usr/lib/<cpu>-linux-gnu/` (the
# multiarch root), but `ExtUtils::Embed::ldopts` emits
# `-L<archlibexp>/CORE -lperl` so the linker only searches the CORE/ dir
# for libperl.so. Symlink the multiarch libperl.so into the perl/<ver>/CORE
# dir so plperl's `cc.links(perl_alloc, ...)` probe succeeds. The version
# dir is discovered from the tree rather than pinned, so this tracks
# whatever Debian perl the sysroot ships.
#
# `derive_multiarch` reads the triplet from the sysroot tree (not `uname -m`,
# which reports the HOST arch and breaks plperl's `cc.links` probe under
# cross-compile, where the sysroot carries the TARGET arch).
multiarch=$(derive_multiarch "$SR") || exit 1
multiarch_lib="$SR/usr/lib/$multiarch"
for perl_core in "$multiarch_lib"/perl/*/CORE; do
    if [ -e "$multiarch_lib/libperl.so" ] && [ -d "$perl_core" ]; then
        ln -sf "$multiarch_lib/libperl.so" "$perl_core/libperl.so"
    fi
done

# Prefer perl-base's copy of each Config file (it's the one perl-base's
# perl binary loads). Fall back to any matching file if the perl-base
# layout isn't present (defensive — runtime-only sysroots without perl
# skip the sed entirely).
config_heavy=$(find "$SR" -name Config_heavy.pl -type f -path '*/perl-base/*' 2>/dev/null | head -1)
[ -z "$config_heavy" ] && config_heavy=$(find "$SR" -name Config_heavy.pl -type f 2>/dev/null | head -1) || true

config_pm=$(find "$SR" -name Config.pm -type f -path '*/perl-base/*' 2>/dev/null | head -1)
[ -z "$config_pm" ] && config_pm=$(find "$SR" -name Config.pm -type f 2>/dev/null | head -1) || true

if [ -n "$config_heavy" ]; then
    sed -i \
        -e "/^archlib=/s|'/|'${SR}/|" \
        -e "/^installarchlib=/s|'/|'${SR}/|" \
        -e "s| -L/| -L${SR}/|g" \
        -e "/^libpth=/s|'/|'${SR}/|g" \
        -e "/^libpth=/s| /| ${SR}/|g" \
        -e "/^libspath=/s|'/|'${SR}/|g" \
        -e "/^libspath=/s| /| ${SR}/|g" \
        -e "/^libsdirs=/s| /| ${SR}/|g" \
        "$config_heavy"
fi

if [ -n "$config_pm" ]; then
    sed -i \
        -e "/archlibexp =>/s|'/|'${SR}/|" \
        -e "/privlibexp =>/s|'/|'${SR}/|" \
        -e "/sitearchexp =>/s|'/|'${SR}/|" \
        -e "/sitelibexp =>/s|'/|'${SR}/|" \
        -e "/scriptdir =>/s|'/|'${SR}/|" \
        -e "/libpth =>/s|'/|'${SR}/|" \
        -e "/libpth =>/s| /| ${SR}/|g" \
        "$config_pm"
fi

# Symlink the clang wrapper. Meson's `find_program(llvm_binpath /
# 'clang')` resolves through `$SR/usr/lib/llvm-14/bin/clang` and
# canonicalizes the symlink → the @libc_sysroot wrapper's persistent
# absolute path gets baked into `Makefile.global`. PGXS extensions
# resolve `$(CLANG)` to that persistent path during JIT bitcode build,
# so the clang invocation survives every sandbox teardown.
mkdir -p "$SR/usr/lib/llvm-$llvm_major/bin"
ln -sf "$wrapper_abs" "$SR/usr/lib/llvm-$llvm_major/bin/clang"

# Symlink the sysroot's multiarch libs into the chroot's standard lib paths so
# build-time ELFs (perl, llvm-config, libllvm14, msgfmt, ...) resolve their
# NEEDED .so via ld.so's default search, without the sandbox manifest having to
# bind-mount host /lib/<arch>/lib*.so* in. `symlink_chroot_libs` skips
# pre-existing targets (`.bazelrc.sandbox_linux_<arch>` still bind-mounts the
# toolchains_llvm libc/libstdc++/libgcc_s/libz/libtinfo set, needed by
# exec-config tool builds) and best-effort suppresses EROFS on the sandbox's
# read-only lib dirs (the libs that fail there, e.g. libdbus, are runtime-only
# and reach PG via tar packaging, not these chroot symlinks).
symlink_chroot_libs "$SR" "$multiarch"

echo "$SR"
