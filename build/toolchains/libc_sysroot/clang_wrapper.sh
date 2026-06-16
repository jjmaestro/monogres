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
# --sysroot=); four more reach bazel's external/ dir.
#
# The sysroot's arch (`amd64` / `arm64`, the basename of $sysroot) is the
# TARGET arch: the arch of the headers/libs in the tree, i.e. what this
# invocation compiles FOR. The arch the wrapper is RUNNING on (the EXEC arch)
# is the kernel's `uname -m`. The two split independently:
#
# - The exec'd clang binary must be an EXEC-arch ELF, so the
#   `cc_toolchain_layout` adapter repo (`@llvm_toolchain_<arch>`, whose `bin/`
#   carries the Debian-sourced clang hardlinked from the matching
#   `@llvm_sysroot` tree) is selected by the EXEC arch. Debian's clang is a
#   native cross-compiler (all LLVM targets enabled), so one host binary
#   serves every target arch.
# - When the two arches differ (cross-compile), clang needs an explicit
#   `--target=` for the sysroot's arch; bare clang defaults to the arch it
#   runs on and would emit EXEC-arch code against TARGET-arch headers/libs.
#   When they match (native), no flag is passed and clang's default triple
#   applies, keeping native invocations byte-identical to a plain
#   `clang --sysroot=...` call.
real=$(readlink -f "${0}")
sysroot=$(dirname "$(dirname "$(dirname "$(dirname "$(dirname "${real}")")")")")
external=$(dirname "$(dirname "$(dirname "$(dirname "${sysroot}")")")")
target_arch=$(basename "${sysroot}")

exec_machine=$(uname -m)
case "${exec_machine}" in
    x86_64) exec_arch=amd64 ;;
    aarch64) exec_arch=arm64 ;;
    *)
        echo "clang_wrapper: unsupported exec arch '${exec_machine}'" >&2
        exit 1
        ;;
esac

target_flag=
if [ "${target_arch}" != "${exec_arch}" ]; then
    case "${target_arch}" in
        amd64) target_flag=--target=x86_64-linux-gnu ;;
        arm64) target_flag=--target=aarch64-linux-gnu ;;
        *)
            echo "clang_wrapper: unsupported sysroot arch '${target_arch}'" >&2
            exit 1
            ;;
    esac
fi

# No linker selection here: the wrapper serves compile-only invocations (JIT
# bitcode `-c`) as well as links, and a link-only flag would draw "argument
# unused during compilation" warnings that confuse autoconf probes which
# parse compiler warnings. Cross link invocations carry `-fuse-ld=lld` via
# the LDFLAGS their build system passes (`pg_build_make` bakes it into
# `Makefile.global` under cross-compile).
#
# The clang to exec lives in the `cc_toolchain_layout` adapter repo for the EXEC
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
for candidate in "${external}"/*"llvm_toolchain_${exec_arch}"/bin/clang; do
    if [ -x "${candidate}" ]; then
        clang="${candidate}"
        break
    fi
done

if [ -z "${clang}" ]; then
    echo "clang_wrapper: no llvm_toolchain_${exec_arch}/bin/clang under" \
        "${external}" >&2
    exit 1
fi

# ${target_flag:+...} expands to nothing for native invocations, so no empty
# argument is passed.
exec "${clang}" ${target_flag:+"${target_flag}"} --sysroot="${sysroot}" "$@"
