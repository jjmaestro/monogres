#!/bin/bash

set -euo pipefail

_build_all_introspect() {
    # Build all introspect (manual) targets from //postgres
    bazel query 'filter("postgres~.*--introspect$", //postgres/...)' |
        xargs bazel build
}

_make_comparable() {
    local json="$1"
    local pg_version="$2"

    sed -E "
        # Bazel cache root. Matches both host (~/.cache/bazel/...) and container
        # (/cache/bazel-cache/bazel/...) layouts.
        s;/[^\"]*_bazel_[a-z]+/[a-f0-9]+;<BAZEL_CACHE>;g
        s;<BAZEL_CACHE>/sandbox/[a-z]+-sandbox/[0-9]+/execroot/_main;<BAZEL_CACHE>/<SANDBOX>/<BAZEL-BUILD>;g
        s;<BAZEL_CACHE>/execroot/_main;<BAZEL_CACHE>/<BAZEL-BUILD>;g

        # Cleanup remaining tokens like PG version, build architecture, etc
        s;${pg_version};<PG_VERSION>;g
        s;postgres~<PG_VERSION>~[a-z]+;<PG_TARGET>;g
        s;aarch64;{arch};g
        s;x86_64;{arch};g
        s;amd64;{arch};g
        s;k8;{arch};g
    " "${json}"
}
export -f _make_comparable

_make_comparable_all() {
    local json_dir="postgres/introspect/json"

    rm -rf "${json_dir}"/postgres~*.json

    # shellcheck disable=SC2016
    find bazel-bin/postgres/postgres~*--introspect \
        -name "*.json" \
        -path "*--introspect/*" \
        -type f -print0 |
    xargs -0 -I@ /bin/bash -c '
        # Extract version and option_set from the path:
        # .../external/+monoext+pg/<version>/<option_set>/introspect/tar.json
        # echo "input: @"

        dir="$(dirname "$(dirname "@")")"
        # echo "dir: $dir"
        option_set="$(basename "${dir}")"
        # echo "option_set: $option_set"
        version="$(basename "$(dirname "${dir}")")"
        # echo "version: $version"
        outname="$(basename "@")"
        # echo "outname: $outname"

        _make_comparable "@" "${version}" >| "'"${json_dir}"'/${outname}"
    '
    chmod 444 "${json_dir}"/*.json
}

_build_all_introspect
_make_comparable_all
