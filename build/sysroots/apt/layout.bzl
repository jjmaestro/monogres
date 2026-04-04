"""Debian library-directory layout for `sysroots.apt(...)` hubs.

Derives, in Starlark from the arch alone (no tree read, no shell, no label-path
parsing), the facts a consumer needs to join paths into a Debian sysroot:

  * `multiarch(arch)`: the Debian multiarch tuple, `<cpu>-linux-gnu` (e.g.
    `x86_64-linux-gnu` for `amd64`). It names Debian's per-arch library
    directory and, being a GNU triple with the vendor field omitted, is also a
    valid target triple, so the same string serves lib paths and autoconf
    `--host` / clang `--target`.
  * `libdirs(arch)`: the sysroot-relative library directories,
    `["usr/lib/<tuple>", "lib/<tuple>"]`.

This is the apt (Debian) layer's own layout; other package managers (rpm, apk)
add their own layout module next to their tag class. See
https://wiki.debian.org/Multiarch/Tuples.
"""

load("//common:archs.bzl", "ARCH_CPU")

# A Debian multiarch tuple renders `<cpu>-linux-gnu`: linux kernel, glibc ABI,
# no vendor field.
_OS = "linux"

_ABI = "gnu"

def multiarch(arch):
    """Debian multiarch tuple for `arch` (`amd64` -> `x86_64-linux-gnu`)."""
    return "-".join([ARCH_CPU[arch], _OS, _ABI])

def libdirs(arch):
    """Sysroot-relative Debian library dirs for `arch`.

    `["usr/lib/<tuple>", "lib/<tuple>"]`: the two per-arch multiarch dirs Debian
    splits shared objects and dev libraries across.
    """
    tuple_ = multiarch(arch)
    return ["usr/lib/%s" % tuple_, "lib/%s" % tuple_]
