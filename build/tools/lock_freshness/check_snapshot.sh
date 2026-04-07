#!/bin/sh
# Fail if any apt lock references a snapshot other than the active release's.
#
# Guards against a release bump (the `apt_snapshot` in the `RELEASES` table) that
# forgot to regenerate the checked-in locks: the drift surfaces here, in the
# `bazel test` lane (the manual prek step), instead of as a silently stale build
# that fetches the wrong snapshot.
#
# argv: <expected-snapshot> <lock> [<lock> ...]
set -eu

expected="$1"
shift

rc=0
for lock in "$@"; do
    if ! grep -q "\"snapshot\": \"${expected}\"" "${lock}"; then
        echo "STALE: ${lock}: top-level \"snapshot\" != ${expected}" >&2
        rc=1
    fi

    foreign="$(grep -oE 'archive/debian/[0-9]{8}T[0-9]{6}Z' "${lock}" |
        grep -v "${expected}" | sort -u || true)"
    if [ -n "${foreign}" ]; then
        echo "STALE: ${lock}: package URLs point at other snapshot(s):" >&2
        echo "${foreign}" >&2
        rc=1
    fi
done

if [ "${rc}" -eq 0 ]; then
    echo "OK: every apt lock is pinned to ${expected}"
fi
exit "${rc}"
