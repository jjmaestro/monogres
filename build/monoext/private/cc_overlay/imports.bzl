"""External cc_import + static-dep resolution for the native cc_* overlay.

The introspect executable / module / shared-library link lines name three kinds
of dependency: the overlay's own convenience archives (`.a` under the source
tree), the external shared / static libraries from the buildtime sysroot
(openssl, icu, the static libstdc++ ICU pulls in, ...), and the bare `-l<name>`
libraries the cc_toolchain's own sysroot does not provide. These helpers split a
link line into the overlay's static-lib deps and the external libraries rendered
as cc_imports, plus the meson-merged companions the link line omits (the `_crc`
sse4.2 sibling, the shared libpq frontends bind).
"""

load(
    ":flags.bzl",
    "MULTIARCH",
    "STDCXX_STATIC",
    "SYSROOT",
    "rel_sysroot",
    "resolve_sysroot",
)

# `-l<name>` libraries the cc_toolchain's own sysroot already provides (libm,
# libc, ...), kept as link flags. Every other `-l<name>` / absolute `.so` in the
# link line comes from the buildtime sysroot and is rendered as a cc_import.
_TOOLCHAIN_LIBS = ["m", "c", "dl", "rt", "pthread"]

def _imp_name(lib_path):
    """cc_import target name for a sysroot library path.

    `sysroot/usr/lib/x86_64-linux-gnu/libssl.so` -> `imp_ssl`;
    `.../mit-krb5/libgssapi_krb5.so` -> `imp_gssapi_krb5`.
    """
    base = lib_path.rsplit("/", 1)[-1]
    if base.startswith("lib"):
        base = base[len("lib"):]
    base = base.split(".", 1)[0]
    return "imp_" + base.replace("-", "_")

def link_static_deps(params):
    """The overlay's own static-lib deps from a link line.

    The link line lists the convenience archives as overlay-relative paths
    (`src/port/libpgport_srv.a`, `src/backend/parser/parser.a`, ...); map each
    to its `:name` cc_library label (the archive basename without `.a`). Overlay
    shared libraries (libpq.so.5.16) are handled separately as dynamic_deps.

    Args:
        params: a link line's introspect `parameters`.

    Returns:
        The `:name` cc_library labels for the convenience archives it links.
    """
    deps = []
    for p in params:
        if p.endswith(".a") and not p.startswith("-") and "/sysroot/" not in p:
            name = p.rsplit("/", 1)[-1][:-len(".a")]
            label = ":" + name
            if label not in deps:
                deps.append(label)
    return deps

def links_shared_libpq(params):
    """Whether a link line links the overlay's shared libpq (libpq.so.5.16).

    Args:
        params: a link line's introspect `parameters`.

    Returns:
        True if the line links the overlay's shared libpq.
    """
    for p in params:
        if p.startswith("src/interfaces/libpq/libpq.so"):
            return True
    return False

def crc_sibling_deps(deps, lib_names):
    """Add the `_crc` companion lib for any base lib linked without it.

    meson merges the sse4.2 crc objects (libX_crc) into the frontend libX via
    `objects:`, so the frontend link line names only libX; the server variant
    lists both libX_srv and libX_srv_crc. Neither relationship is in the
    introspect, so add libX_crc whenever libX is linked and its companion is a
    rendered lib not already present (a no-op for the server, which lists both).

    Args:
        deps: the static-lib `:name` deps already resolved for a target.
        lib_names: the set of rendered convenience-lib names.

    Returns:
        The `_crc` companion `:name` deps to add.
    """
    extra = []
    for d in deps:
        crc = d + "_crc"
        if crc[len(":"):] in lib_names and crc not in deps and crc not in extra:
            extra.append(crc)
    return extra

def external_imports(params):
    """External libraries from an executable link line, as cc_import specs.

    Four shapes map to the buildtime sysroot: an absolute `.so` path (openssl,
    icu, ...), an absolute `.a` path (pltcl's libtclstub8.6.a), `-l:libstdc++.a`
    (the static C++ runtime ICU pulls in), and a bare `-l<name>` not provided by
    the cc_toolchain's own sysroot (pam, zstd).

    Args:
        params: an executable / module link line's introspect `parameters`.

    Returns:
        Deduped structs, each with `name` and one of `shared` / `static` set.
    """
    imports = []
    seen = {}
    for p in params:
        shared = None
        static = None
        if p.endswith(".so") and "/sysroot/" in p:
            shared = rel_sysroot(p)
        elif p.endswith(".a") and "/sysroot/" in p:
            static = rel_sysroot(p)
        elif p == "-l:libstdc++.a":
            static = STDCXX_STATIC
        elif p.startswith(
            "-l",
        ) and not p.startswith("-l:") and p[2:] not in _TOOLCHAIN_LIBS:
            # Resolve any version placeholder in the lib name (e.g. the JIT's
            # `-lLLVM-<LLVM_VERSION>`) the same way sysroot paths are resolved,
            # so the cc_import points at the real per-release soname.
            shared = "%s/usr/lib/%s/lib%s.so" % (
                SYSROOT,
                MULTIARCH,
                resolve_sysroot(p[2:]),
            )
        else:
            continue
        name = _imp_name(shared or static)
        if name in seen:
            continue
        seen[name] = True
        imports.append(struct(name = name, shared = shared, static = static))
    return imports
