#!/bin/bash
# shellcheck disable=SC2154,SC2250,SC2292,SC2249,SC2312
# Populate the hermetic test chroot with a runtime library closure assembled
# from sysroot tars. The extract / multiarch / chroot-symlink mechanics are
# shared with the build-time setup via `base/sysroot_lib.sh` (sourced); this
# script layers the multi-tar closure + the chroot/run mode on top.
#
# The hermetic-linux sandbox starts each action from an empty chroot whose
# bind-mount manifest is loader-only for general binaries (the ELF loader comes
# from --config=host-amd64). A dynamic glibc binary therefore finds no libc and
# no NEEDED .so until this script symlinks a sysroot's multiarch libraries into
# the chroot's standard /lib/<triplet> + /usr/lib/<triplet> paths, where ld.so's
# default search resolves them with no LD_LIBRARY_PATH. The chroot root is
# writable at action time (the build's sysroot_setup.sh relies on the same).
#
# Usage:
#   closure_setup.sh <lib> <bsdtar> <staging_dir> <tar> [<tar> ...] [--mode chroot|run]
#
#   <lib>          sysroot_lib.sh, sourced (cross-package from base/, so the
#                  harness passes its resolved path in)
#   <bsdtar>       static bsdtar (runs before any libc is present)
#   <staging_dir>  where the tars are extracted (e.g. "$TEST_TMPDIR/closure")
#   <tar>...       sysroot tars, applied in order (later wins on overlap):
#                  glibc (@libc_sysroot) first, then the runtime closure, then
#                  any test-only closure.
#   --mode         chroot (default, or $CLOSURE_MODE): the sandboxed lane, where
#                  ld.so's default search must resolve from the chroot's
#                  /lib/<triplet>, so symlink the closure libs there. run: the
#                  un-sandboxed `bazel run` lane (interactive psql), which has a
#                  real loader + glibc and reaches the closure via
#                  LD_LIBRARY_PATH, so skip the (un-writable host) /lib symlinks.
#
# Prints the detected multiarch triplet on stdout.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: $0 <lib> <bsdtar> <staging_dir> <tar> [<tar> ...] [--mode chroot|run]" >&2
  exit 2
fi

# Shared extract / multiarch / chroot-symlink mechanics. sysroot_lib.sh lives in
# base/ (cross-package), so the harness passes its resolved path in as $1.
# shellcheck disable=SC1091 source=../base/sysroot_lib.sh
. "$1"
shift

bsdtar=$1
staging=$2
shift 2

# A trailing `--mode chroot|run` selects whether the closure libs are symlinked
# into the chroot's standard lib paths (chroot, default) or only extracted +
# reported (run). Strip it from the positional tar list before extraction; an
# env CLOSURE_MODE is the fallback default.
mode="${CLOSURE_MODE:-chroot}"
tars=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    *) tars+=("$1"); shift ;;
  esac
done

extract_tars "$bsdtar" "$staging" "${tars[@]}"

multiarch=$(derive_multiarch "$staging") || exit 1

# Only the sandboxed chroot lane needs the symlinks: the un-sandboxed run lane
# (interactive psql) has a real loader + glibc and reaches the closure via
# LD_LIBRARY_PATH, and the host /lib is not ours to write.
if [ "$mode" = chroot ]; then
  symlink_chroot_libs "$staging" "$multiarch"
fi

printf '%s\n' "$multiarch"
