#!/bin/sh
# shellcheck disable=SC2154,SC2250
# Action-time setup of the per-PG sysroot for `pg_build` / `pgxs_build`.
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

tar_abs=$1
wrapper_abs=$2
bsdtar_abs=$3
llvm_major=$4

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
#
# `multiarch` is derived from the sysroot tree (the only `*-linux-gnu`
# child of `usr/lib/`) rather than `uname -m`. Under cross-compile
# (host=amd64, target=arm64) `uname -m` reports the HOST arch, but the
# sysroot's multiarch dir carries the TARGET arch; mismatching the two
# breaks plperl's `cc.links` probe at link time.
multiarch=
for d in "$SR/usr/lib/"*-linux-gnu; do
    base=$(basename "$d")
    case "$base" in
        x86_64-linux-gnu|aarch64-linux-gnu) multiarch=$base ;;
        *) ;;
    esac
done
[ -n "$multiarch" ] || { echo "no multiarch dir found in $SR/usr/lib" >&2; exit 1; }
multiarch_lib="$SR/usr/lib/$multiarch"
for perl_core in "$multiarch_lib"/perl/*/CORE; do
    if [ -e "$multiarch_lib/libperl.so" ] && [ -d "$perl_core" ]; then
        ln -sf "$multiarch_lib/libperl.so" "$perl_core/libperl.so"
    fi
done

# Symlink the clang wrapper. Meson's `find_program(llvm_binpath /
# 'clang')` resolves through `$SR/usr/lib/llvm-14/bin/clang` and
# canonicalizes the symlink → the @libc_sysroot wrapper's persistent
# absolute path gets baked into `Makefile.global`. PGXS extensions
# resolve `$(CLANG)` to that persistent path during JIT bitcode build,
# so the clang invocation survives every sandbox teardown.
mkdir -p "$SR/usr/lib/llvm-$llvm_major/bin"
ln -sf "$wrapper_abs" "$SR/usr/lib/llvm-$llvm_major/bin/clang"

# Symlink sysroot libs into the chroot's standard `/lib/<cpu>-linux-gnu/`
# and `/usr/lib/<cpu>-linux-gnu/` paths so ELFs that load deps via ld.so's
# default search list (perl from @perl_sysroot, llvm-config, libllvm14,
# msgfmt, etc.) find their NEEDED libs without the hermetic-Linux-sandbox
# manifest having to bind-mount host /lib/<cpu>-linux-gnu/lib*.so* files
# in. The chroot is a per-action tmpfs so these symlinks come back fresh
# for every action run.
#
# Existing-target skip: `.bazelrc.sandbox_linux_<arch>` still bind-mounts
# the toolchains_llvm libc / libstdc++ / libgcc_s / libz / libtinfo set
# (those are needed by exec-config actions that build their own tools via
# clang outside any sysroot-extraction context; see the manifest comment).
# `-e` covers those: `ln -sf` over a bind-mounted target can fail or have
# unexpected semantics, so let the bind-mount win where they overlap. The
# loop still fills in the rest of the sysroot's lib trees (libcrypt,
# libgssapi-krb5, libssl, libxml2, libllvm14, ...) at standard paths so
# their consumers don't need explicit per-tool LD_LIBRARY_PATH entries.
#
# Best-effort: Bazel's hermetic linux-sandbox keeps `/lib/<multiarch>/` and
# `/usr/lib/<multiarch>/` read-only after applying the bind-mount manifest.
# `mkdir -p` is a no-op on an existing dir (success); `ln -s` against a
# read-only parent fails with EROFS. Suppress the failure and keep going:
# the affected lib (e.g. libdbus-1.so.3 transitively pulled by
# libavahi-compat-libdnssd-dev / libsystemd-dev) is not actually needed at
# build time by any of our build-time ELFs (clang, ld, ar, perl,
# llvm-config, ...); only PG's runtime needs it, and the runtime image
# pulls the sysroot's copy through tar packaging, not through these
# chroot-path symlinks.
for srcdir in "$SR/lib/$multiarch" "$SR/usr/lib/$multiarch"; do
    [ -d "$srcdir" ] || continue
    dstdir=${srcdir#"$SR"}
    mkdir -p "$dstdir" 2>/dev/null || continue
    for src in "$srcdir"/*; do
        [ -e "$src" ] || continue
        dst="$dstdir/$(basename "$src")"
        [ -e "$dst" ] && continue
        ln -s "$src" "$dst" 2>/dev/null || true
    done
done

echo "$SR"
