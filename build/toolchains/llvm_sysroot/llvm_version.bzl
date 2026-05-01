"""LLVM version constants for the active Debian release, from the profile.

`LLVM_MAJOR` is the major-version digit Debian uses in install paths
(`/usr/lib/llvm-N/`) and package names (`clang-N`, `lld-N`, `llvm-N-dev`).

`LLVM_VERSION` is the full version string `toolchains_llvm`'s
`llvm.toolchain(llvm_version = ...)` consumes; the `cc_toolchain_layout` adapter
derives its resource-dir path from it.
"""

load("@platform_debian//:versions.bzl", "RELEASE")

LLVM_MAJOR = RELEASE.llvm_major
LLVM_VERSION = RELEASE.llvm_version
