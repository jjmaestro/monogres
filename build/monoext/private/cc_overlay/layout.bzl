"""Overlay layout: the introspect -> package map (the shared source of truth).

A pure function (no Star, no repository_ctx) shared by the repo rule (which uses
the package set to drive the source symlink merge) and, in later phases, the
renderer and the hub facade. Keeping it pure and shared means the overlay tree
and any facade over it derive from one computation and cannot drift.

The deferral lists live here too, since they define the rendered target set: the
renderer filters by them and `overlay_layout` mirrors that filtering, so both
agree on which targets (and therefore which directories) the overlay builds.
"""

# Static libs held back from the overlay. libpgcommon_shlib_config_info is the
# config_info variant compiled for shared libraries; meson builds it but nothing
# in this option set links it (only pg_config reads the build data, through the
# frontend config_info variant), so it is not rendered.
DEFERRED_LIBS = [
    "libpgcommon_shlib_config_info",
]

# Installed executables all render as frontends, including the ecpg preprocessor
# (its grammar is generated: bison reads preproc.y, which the perl parse.pl
# emits from the backend gram.y and the ecpg addon files) and the regress
# drivers.
DEFERRED_EXES = []

# Shared modules held back from the overlay (none: the src/ loadables, the PLs,
# and every contrib extension render).
DEFERRED_MODULES = []

def pkg_of(defined_in):
    """The overlay package path for a target's meson `defined_in` path.

    `.../gh/src/interfaces/libpq/meson.build` -> `src/interfaces/libpq`.

    Args:
        defined_in: a target's introspect `defined_in` (a meson.build path).

    Returns:
        The overlay-root-relative directory that owns the target.
    """
    return defined_in.split("/gh/", 1)[1].rsplit("/meson.build", 1)[0]

def _module_so_name(target):
    """A shared module's output .so basename (the rendered cc_binary name)."""
    return target["filename"][0].rsplit("/", 1)[-1]

def overlay_layout(introspect):
    """Map the introspect to the overlay package layout and its public facade.

    Collects the source directories that own a rendered target: a static library
    (minus DEFERRED_LIBS), an installed executable (minus DEFERRED_EXES), or a
    shared module (minus DEFERRED_MODULES). Each is the home package of its
    targets. The renderer's deferrals are mirrored so the package set matches
    what the overlay builds.

    `facade` is the per-package public-target map the hub aliases under
    `@<hub>//<v>/<opt>/cc/`: the named libs / executables / modules (a lib with
    no compiled sources is skipped, as the renderer skips it) plus the shared
    client-library variants (libpq and the ecpg family) the renderer emits
    beside their static libs. It mirrors render.bzl's selection (KEEP IN SYNC);
    the internal targets the renderer also emits (the header libs, the
    cc_imports, the per-package :hdrs / :textual / :include, the codegen
    genrules, the JIT bitcode) are deliberately absent.

    Args:
        introspect: the decoded introspect JSON for one (version, option_set).

    Returns:
        A struct with `packages` (sorted target-owning directories) and `facade`
        ({package: sorted public target names}).
    """
    packages = {}
    facade = {}
    for t in introspect["targets"]:
        type_ = t["type"]
        name = t["name"]
        tname = None
        if type_ == "static library":
            if name in DEFERRED_LIBS:
                continue
            ts = t["target_sources"][0]
            if ts.get("sources") or ts.get("generated_sources"):
                tname = name
        elif type_ == "executable":
            if not t.get("installed") or name in DEFERRED_EXES:
                continue
            tname = name
        elif type_ == "shared module":
            if name in DEFERRED_MODULES:
                continue
            tname = _module_so_name(t)
        else:
            continue
        pkg = pkg_of(t["defined_in"])
        packages[pkg] = True
        if tname:
            facade.setdefault(pkg, {})[tname] = True

    # The shared client libraries (libpq and the ecpg family) the renderer emits
    # as a cc_library (<lib>_shared) + cc_shared_library (<lib>_so) pair beside
    # the static lib, in the defining package (clients link the shared variant).
    for t in introspect["targets"]:
        if t["type"] == "shared library":
            lp = facade.setdefault(pkg_of(t["defined_in"]), {})
            lp[t["name"] + "_shared"] = True
            lp[t["name"] + "_so"] = True

    return struct(
        packages = sorted(packages.keys()),
        facade = {p: sorted(facade[p].keys()) for p in sorted(facade.keys())},
    )
