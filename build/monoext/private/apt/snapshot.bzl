"""
Debian snapshot pin for every apt-resolution consumer in `monoext`.

Re-exports the active release's snapshot from `@platform_debian//:versions.bzl`,
so a release bump cascades through every lockfile in lockstep: `//catalog`'s
shared `pg_pkgs.lock`, the per-PG-version `@pgbuildtime_<key>` hubs, and the
`@llvm_sysroot` toolchain sysroot declared at the root `MODULE.bazel`. Each
consumer's `bazel run @<repo>//.../lock:update` must be re-run after a bump.

The generic `//sysroots` module never bakes a snapshot pin of its own (every
`sysroots.<pkg>(...)` tag takes `snapshot` as an explicit arg).
"""

load("@platform_debian//:versions.bzl", "RELEASE")

SNAPSHOT = RELEASE.apt_snapshot
