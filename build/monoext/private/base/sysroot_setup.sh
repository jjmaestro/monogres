#!/bin/sh
# shellcheck disable=SC2154,SC2250
# Action-time setup of the per-PG sysroot for `pg_build` / `pgxs_build`.
#
# Inputs (both come from `$(execpath ...)` substitutions, which
# `rules_foreign_cc` auto-prepends with `$EXT_BUILD_ROOT/` — see
# https://github.com/bazel-contrib/rules_foreign_cc/blob/0.12.0/foreign_cc/private/make_env_vars.bzl#L123-L124
# so the args land here as absolute paths inside the action sandbox):
#   $1  Absolute path of the per-PG sysroot tar.
#   $2  Absolute path of the hermetic `bsdtar` binary from
#       `@bsd_tar_toolchains_<host_arch>//:tar`. Same `bsdtar` family
#       that writes the archive in `sysroots/apt/private/repo.bzl`'s
#       `_make_sysroot_tar`, so the pax-format snapshot round-trips
#       end-to-end (symbolic links, long paths, uid/gid/mtime, and
#       pax extended attributes preserved verbatim).
#
# Side effects:
#   - Extracts the tar to `$EXT_BUILD_ROOT/sysroot/`. The tar carries the
#     full normalized payload (symlinks relativized, ld scripts
#     `=`-prefixed, extra_files injected) — all the Tier-1 work done at
#     `//sysroots/apt` repo-rule time.
#   - Symlinks the multiarch libperl.so into the perl/<ver>/CORE/ dir so
#     plperl's `cc.links(perl_alloc, ...)` probe resolves libperl (the
#     version dir is discovered from the tree, not pinned).
#
# Output:
#   Prints `$EXT_BUILD_ROOT/sysroot` (absolute). Caller assigns this to
#   `SYSROOT_DIR`. rules_foreign_cc does NOT auto-prepend `$EXT_BUILD_ROOT/`
#   here (the printed path doesn't contain `external/`).
set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 <tar-abs> <bsdtar-abs>" >&2
    exit 2
fi

tar_abs=$1
bsdtar_abs=$2

SR=${EXT_BUILD_ROOT}/sysroot
mkdir -p "$SR"
"$bsdtar_abs" -xf "$tar_abs" -C "$SR"

# Bridge Debian's multiarch libperl layout to the Config_overrides shim's
# claimed `archlibexp` ($SR/usr/lib/<cpu>-linux-gnu/perl/<ver>). Debian's
# libperl-dev ships `libperl.so` at `$SR/usr/lib/<cpu>-linux-gnu/` (the
# multiarch root), but `ExtUtils::Embed::ldopts` emits
# `-L<archlibexp>/CORE -lperl` so the linker only searches the CORE/ dir
# for libperl.so. Symlink the multiarch libperl.so into the perl/<ver>/CORE
# dir so plperl's `cc.links(perl_alloc, ...)` probe succeeds. The version
# dir is discovered from the tree rather than pinned, so this tracks
# whatever Debian perl the sysroot ships.
arch=$(uname -m)
multiarch_lib="$SR/usr/lib/$arch-linux-gnu"
for perl_core in "$multiarch_lib"/perl/*/CORE; do
    if [ -e "$multiarch_lib/libperl.so" ] && [ -d "$perl_core" ]; then
        ln -sf "$multiarch_lib/libperl.so" "$perl_core/libperl.so"
    fi
done

echo "$SR"
