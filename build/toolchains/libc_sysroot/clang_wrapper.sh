#!/bin/sh
# Self-relative wrapper for Postgres JIT bitcode compile + PGXS extensions.
# Bakes `--sysroot=<sysroot>` into every clang invocation so PGXS / JIT bitcode
# compilation runs against the hermetic Debian sysroot, not host headers.
# `readlink -f $0` follows symlink chains to the canonical file location so
# the path arithmetic stays correct even when invoked via the apt-sysroot
# symlink that pg_build planted at `$SYSROOT_DIR/usr/lib/llvm-14/bin/clang`.
#
# Wrapper lives at:
#   <external>/<libc_sysroot>/<distro>/<version>/<arch>/usr/lib/llvm-14/bin/clang
# Five dirnames from $real reach the per-arch sysroot root (passed to clang as
# --sysroot=); four more reach bazel's external/ dir. The arch (`amd64` /
# `arm64`) is the basename of $sysroot; it selects the matching exec-arch
# `cc_toolchain_layout` adapter repo (`@llvm_toolchain_<arch>`), whose `bin/`
# carries the Debian-sourced clang hardlinked from `@llvm_sysroot`.
real=$(readlink -f "${0}")
sysroot=$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "${real}")")")")")
external=$(dirname "$(dirname "$(dirname "$(dirname "${sysroot}")")")")
arch=$(basename "${sysroot}")

# The clang to exec lives in the `cc_toolchain_layout` adapter repo for that
# arch, whose directory under `external/` is its CANONICAL repo name. The only
# part of that name we choose is the apparent name it ends with, the one this
# repo is declared under; everything before it Bazel derives, and derives
# differently between versions (`~` separators before Bazel 8, `+` from 8 on)
# and by position, since a repo declared with `use_repo_rule` is numbered by
# where its declaring call sits among all of them in `MODULE.bazel`. So match on
# the apparent name alone and let Bazel spell the rest however it likes.
#
# That leaves the match pinned by three things: the arch-suffixed apparent name,
# which no other repo in the graph ends with (`toolchains_llvm`'s own hub ends
# at `llvm_toolchain`, unsuffixed); the `bin/clang` below it; and `-x`. Globbing
# one directory level is cheap, and in a sandboxed action there is barely
# anything to walk, since only declared inputs are staged.
#
# The path cannot be passed in instead: `pg_build` redirects the sysroot's
# `usr/lib/llvm-<major>/bin/clang` here so that meson's `find_program` and the
# `$(CLANG)` in Postgres's installed `Makefile.global` resolve to it, and both
# invoke it by that one absolute path with no argument of ours. Hence `$0`, as
# the adapter's own shim likewise takes its exec root.
#
# An unmatched glob stays literal in POSIX sh, so the `-x` test fails and the
# empty `clang` reports it rather than exec'ing a pattern.
clang=
for candidate in "${external}"/*"llvm_toolchain_${arch}"/bin/clang; do
    if [ -x "${candidate}" ]; then
        clang="${candidate}"
        break
    fi
done

if [ -z "${clang}" ]; then
    echo "clang_wrapper: no llvm_toolchain_${arch}/bin/clang under" \
        "${external}" >&2
    exit 1
fi

exec "${clang}" --sysroot="${sysroot}" "$@"
