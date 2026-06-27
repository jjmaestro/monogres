"""Overlay layout: the introspect -> package map (the shared source of truth).

A pure function (no Star, no repository_ctx) shared by the repo rule (which uses
the package set to drive the source symlink merge) and, in later phases, the
renderer and the hub facade. Keeping it pure and shared means the overlay tree
and any facade over it derive from one computation and cannot drift.

The deferral lists live here too, since they define the rendered target set: the
renderer filters by them and `overlay_layout` mirrors that filtering, so both
agree on which targets (and therefore which directories) the overlay builds.
"""

# Static libs deferred past the core overlay. The ecpg family needs the ecpg
# codegen (ecpg_config.h, the ecpg kwlists, the preprocessor); the shlib
# config_info variant lands with the shared libpq layout.
DEFERRED_LIBS = [
    "libecpg",
    "libecpg_compat",
    "libpgtypes",
    "libpgcommon_shlib_config_info",
]

# Installed executables not rendered as frontends: ecpg needs the ecpg
# preprocessor codegen (its own phase). Every other installed executable is a
# frontend, including the regress drivers.
DEFERRED_EXES = [
    "ecpg",
]

# Shared modules held back past the core module phase. Contrib modules are
# deferred wholesale by their `defined_in` (see `_is_contrib`).
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

def _is_contrib(defined_in):
    """Whether a target is defined under contrib/ (deferred wholesale)."""
    return "/gh/contrib/" in defined_in

def overlay_layout(introspect):
    """Map the introspect to the overlay package layout.

    Collects the source directories that own a rendered target: a static library
    (minus DEFERRED_LIBS), an installed executable (minus DEFERRED_EXES), or a
    non-contrib shared module (minus DEFERRED_MODULES). Each is the home package
    of its targets. The renderer's deferrals are mirrored so the package set
    matches what the overlay builds.

    Args:
        introspect: the decoded introspect JSON for one (version, option_set).

    Returns:
        A struct with `packages`: the sorted list of target-owning directories.
    """
    packages = {}
    for t in introspect["targets"]:
        type_ = t["type"]
        name = t["name"]
        if type_ == "static library":
            if name in DEFERRED_LIBS:
                continue
        elif type_ == "executable":
            if not t.get("installed") or name in DEFERRED_EXES:
                continue
        elif type_ == "shared module":
            if name in DEFERRED_MODULES or _is_contrib(t["defined_in"]):
                continue
        else:
            continue
        packages[pkg_of(t["defined_in"])] = True
    return struct(packages = sorted(packages.keys()))
