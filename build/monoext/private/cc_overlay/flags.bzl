"""Flag / path reconciliation for the native cc_* Postgres overlay.

Foundational helpers the rest of the overlay renderer builds on: the arch /
version / sysroot constants the introspect sanitizes, the drop sets that
separate PG-semantic flags from the cc_toolchain-injected ones, and the
functions that map introspect source / output / include paths to overlay-root
relative form and reconcile compile / link parameters.

Flag reconciliation (analysis section 6.4): the introspect `parameters`
interleave PG-semantic flags (kept) with flags the Bazel cc_toolchain injects on
every action (dropped). The drop set was verified against a native `bazel aquery
mnemonic(CppCompile, ...)` line, so the overlay does not duplicate `--target=` /
`--sysroot=` / fortify / stack-protector / date-redaction flags.
"""

load("@platform_debian//:versions.bzl", "RELEASE")
load("@sysroots//apt:layout.bzl", "multiarch")
load("//platforms:targets.bzl", "ARCH_CPU")

# Target architecture for the MVP (linux/amd64). The introspect sanitizes the
# multiarch tuple to `<MULTIARCH>`, the CPU name to `<CPU>`, and the Debian/dpkg
# arch to `<ARCH>`; the overlay is amd64-only for now, so resolve all three
# here. A later phase threads the real arch through. `MULTIARCH` (the Debian
# multiarch tuple) comes from the sysroot's own layout; `_CPU` (CPU name) and
# `_ARCH` (dpkg arch) from the arch model.
_ARCH = "amd64"
_CPU = ARCH_CPU[_ARCH]
MULTIARCH = multiarch(_ARCH)

# Version facts the introspect sanitizes alongside the arch, resolved here from
# the release profile: the PL language runtimes (plpython3 links
# libpython<PY_VERSION>, pltcl links libtcl<TCL_VERSION>), Perl
# (share/perl/<PERL_VERSION>), LLVM (llvm-<LLVM_VERSION>), and the Debian
# release the vendored sysroots are keyed by (debian/<DEBIAN_VERSION>).
_PY_VERSION = RELEASE.python_version
_TCL_VERSION = RELEASE.tcl_version
_PERL_VERSION = RELEASE.perl_version
_DEBIAN_VERSION = RELEASE.version
LLVM_VERSION = RELEASE.llvm_major

def resolve_sysroot(rel):
    """Resolve the sysroot path placeholders the introspect sanitizes."""
    return (
        rel
            .replace("<MULTIARCH>", MULTIARCH)
            .replace("<CPU>", _CPU)
            .replace("<ARCH>", _ARCH)
            .replace("<PY_VERSION>", _PY_VERSION)
            .replace("<TCL_VERSION>", _TCL_VERSION)
            .replace("<PERL_VERSION>", _PERL_VERSION)
            .replace("<DEBIAN_VERSION>", _DEBIAN_VERSION)
            .replace("<LLVM_VERSION>", LLVM_VERSION)
    )

# The buildtime sysroot, symlinked to `sysroot/` in the overlay root by the repo
# rule. Mirrors the introspect's own `<BAZEL-BUILD>/sysroot/...` paths, so the
# external shared libraries (openssl, icu, ...) and the static libstdc++ (ICU is
# C++) the link line references map by a plain string rewrite.
SYSROOT = "sysroot"
STDCXX_STATIC = "%s/usr/lib/gcc/%s/%s/libstdc++.a" % (SYSROOT, MULTIARCH, RELEASE.gcc_major)

# Link flags kept verbatim from the introspect executable link line. The rest
# are dropped: the cc_toolchain injects its own (`--target`, `--sysroot`,
# hardening, build-id, hash-style); the static `.a` and external `.so` become
# deps / cc_imports; the `-L` dirs and the buildtime `-Wl,-rpath` are subsumed
# by those (the runtime rpath is a packaging concern handled when the tar
# lands). `-Wl,-export-dynamic` is runtime-critical: it exports the backend
# symbols that dynamically-loaded modules resolve against.
_LINK_KEEP = [
    "-Wl,-export-dynamic",
    "-pthread",
    "-lm",
]

# Flags the @llvm_toolchain cc_toolchain injects itself; drop them from the
# reconciled copts so the native action does not repeat (or fight) them.
_DROP_EXACT = [
    "-fdiagnostics-color=always",
    "-fcolor-diagnostics",
    "-U_FORTIFY_SOURCE",
    "-fstack-protector",
    "-fno-omit-frame-pointer",
    "-Wthread-safety",
    "-Wself-assign",
    "-fPIC",
    "-no-canonical-prefixes",
    "-Wno-builtin-macro-redefined",
]

_DROP_PREFIX = [
    "--target=",
    "--sysroot=",
    "-fuse-ld=",
    "-D__DATE__=",
    "-D__TIME__=",
    "-D__TIMESTAMP__=",
]

def dedup(xs):
    """Remove duplicates from a list, preserving first-seen order.

    Args:
        xs: a list of hashable items.

    Returns:
        A new list with the first occurrence of each item, in order.
    """
    seen = {}
    out = []
    for x in xs:
        if x not in seen:
            seen[x] = True
            out.append(x)
    return out

def _starts_with_any(s, prefixes):
    for p in prefixes:
        if s.startswith(p):
            return True
    return False

def rel_src(path):
    """`.../gh/src/port/path.c` -> `src/port/path.c` (overlay-root relative)."""
    return path.split("/gh/", 1)[-1]

def rel_out(path):
    """Map an introspect generated-output path to overlay-root relative.

    Declared outputs live under the meson build dir, e.g.
    `.../introspect.build_tmpdir/src/include/utils/errcodes.h`; the suffix after
    `introspect.build_tmpdir/` is the overlay-relative path the genrule declares
    (and the cc_toolchain finds via `-Isrc/include` against the genfiles tree).
    """
    return path.split("introspect.build_tmpdir/", 1)[-1]

def _rel_inc(path):
    """Map an introspect `-I` dir to an overlay-root-relative include dir.

    The introspect uses three roots: the generated-header build dir
    (`.../introspect.build_tmpdir/src/...`) and the source tree
    (`.../gh/src/...`), both collapsing to the same overlay-relative `src/...`
    (resolved against both the symlinked source and the genfiles tree); and the
    buildtime sysroot (`<BAZEL-BUILD>/sysroot/usr/include/libxml2`, ...), which
    maps to the overlay `sysroot/...` symlink (arch resolved). An external dep
    whose headers live in a subdir (libxml2's `<libxml/...>`, PAM's security/)
    only resolves with its own `-I`, so these are kept. Returns None for any
    other path.
    """
    for marker in ["introspect.build_tmpdir/", "/gh/"]:
        if marker in path:
            return path.split(marker, 1)[1]
    if "/sysroot/" in path:
        return SYSROOT + "/" + resolve_sysroot(path.split("/sysroot/", 1)[1])
    if "llvm_sysroot/" in path:
        # llvmjit's LLVM-C / LLVM C++ headers. The introspect points at the
        # dedicated @llvm_sysroot, but the per-PG buildtime sysroot carries the
        # same llvm-<ver> tree (same Debian snapshot), so resolve there,
        # dropping the `<distro>/<ver>/<arch>/` prefix.
        rel = path.split("llvm_sysroot/", 1)[1].split("/", 3)[-1]
        return SYSROOT + "/" + resolve_sysroot(rel)
    return None

def includes(params):
    """Collect overlay-relative include dirs from the `-I` flags.

    Skips meson per-target private dirs (`*.p`), which hold no headers the
    overlay needs.

    Args:
        params: a target's introspect compile `parameters`.

    Returns:
        The overlay-relative include dirs named by its `-I` flags.
    """
    incs = []
    for p in params:
        if not p.startswith("-I"):
            continue
        rel = _rel_inc(p[len("-I"):])
        if rel and not rel.endswith(".p") and rel not in incs:
            incs.append(rel)
    return incs

def _fix_string_define(p):
    """Make a `-D<name>="<value>"` string define survive the response file.

    clang's response-file parser strips an unescaped quote pair, so a string
    define would expand to bare tokens (pg_regress's `HOST_TUPLE` /
    `SHELLPROG`). Escape the quotes and substitute `<CPU>`. Space-free values
    only: a value with spaces does not survive even escaped (the VAL_* lesson),
    so it is force-included as a header instead (see render_config_info_vals).
    """
    body = p[len("-D"):]
    if "=" not in body:
        return p
    name, value = body.split("=", 1)
    if len(value) < 2 or not value.startswith("\"") or not value.endswith("\""):
        return p
    inner = value[1:-1].replace("<CPU>", _CPU)
    if " " in inner:
        fail("string define with spaces needs a force-included header: %r" % p)
    return "-D%s=\\\"%s\\\"" % (name, inner)

def copts(params):
    """Reconcile introspect compile `parameters` to PG-semantic copts.

    Drops the cc_toolchain-injected flags (`_DROP_EXACT` / `_DROP_PREFIX`), the
    `-I` dirs (surfaced via `includes`), and the `-idirafter <sysroot>` pairs
    (the toolchain sysroot supplies libc headers; per-target external-dep
    include dirs are added explicitly where needed). Keeps the `-isystem
    <sysroot>` pairs a *-config script contributes, re-rooted at the overlay
    sysroot.

    Args:
        params: a target's introspect compile `parameters`.

    Returns:
        The reconciled, deduplicated copts.
    """
    out = []
    skip = False
    isystem = False
    for p in params:
        if skip:
            skip = False
            continue
        if isystem:
            # The dir `-isystem` introduced. Only a buildtime-sysroot path maps
            # into the overlay (krb5-config prints `-isystem
            # <BAZEL-BUILD>/sysroot/usr/include/mit-krb5`); kept as captured it
            # still carries the placeholder and clang silently ignores a dir
            # that cannot exist. Anything else has no overlay equivalent, so the
            # pair goes the way of the `-I` dirs.
            isystem = False
            if "/sysroot/" in p:
                out.append("-isystem")
                out.append(rel_sysroot(p))
            continue
        if p == "-idirafter":
            skip = True
            continue
        if p == "-isystem":
            isystem = True
            continue
        if p.startswith("-I"):
            continue

        # config_info.c's -DVAL_* build-string defines carry sanitized,
        # non-native values; they are re-emitted per lib (see
        # _CONFIG_INFO_LIBS).
        if p.startswith("-DVAL_"):
            continue
        if p in _DROP_EXACT or _starts_with_any(p, _DROP_PREFIX):
            continue
        if p.startswith("-D") and "=\"" in p:
            out.append(_fix_string_define(p))
            continue
        out.append(p)
    return dedup(out)

def reconcile_build_flags(value):
    """Reconcile a meson VAL_CFLAGS / VAL_LDFLAGS string to portable flags.

    These strings interleave PG-semantic flags (kept) with cc_toolchain-injected
    ones carrying sanitized, non-portable paths (`--sysroot=<BAZEL-BUILD>/...`,
    `--target=<CPU>-...`, `-idirafter <sysroot>`, `-L<sysroot>`, ...). Drop the
    toolchain flags (same drop sets as `copts`, plus -L) and any token still
    carrying a sanitization placeholder, so pg_config reports flags an extension
    build can actually use.

    Args:
        value: a meson VAL_CFLAGS / VAL_LDFLAGS build-string.

    Returns:
        The build-string reduced to portable, deduplicated flags.
    """
    out = []
    skip = False
    for t in value.split(" "):
        if skip:
            skip = False
            continue
        if t == "-idirafter":
            skip = True
            continue
        if not t:
            continue
        if "<" in t:
            continue
        if t.startswith("-I") or t.startswith("-L"):
            continue
        if t in _DROP_EXACT or _starts_with_any(t, _DROP_PREFIX):
            continue
        out.append(t)
    return " ".join(dedup(out))

def rel_sysroot(path):
    """Rewrite an introspect buildtime-sysroot path to overlay-relative.

    `<BAZEL-BUILD>/sysroot/usr/lib/<MULTIARCH>/libssl.so` ->
    `sysroot/usr/lib/x86_64-linux-gnu/libssl.so`: strip everything up to and
    including the `/sysroot/` marker, resolve the sanitized placeholders, and
    re-root at the overlay `sysroot/` symlink.
    """
    return SYSROOT + "/" + resolve_sysroot(path.split("/sysroot/", 1)[1])

def linkopts(params):
    """Reconcile an executable link line to the PG-semantic link flags kept.

    Everything else is dropped: the cc_toolchain injects its own flags, the
    static `.a` / external `.so` become deps and cc_imports, and the `-L` dirs /
    buildtime `-Wl,-rpath` are subsumed by those. See _LINK_KEEP.
    """
    return [p for p in params if p in _LINK_KEEP]
