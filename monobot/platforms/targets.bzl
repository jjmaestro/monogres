"""Single source of truth for the architectures monobot targets.

Every file that needs to iterate over, select on, or name an architecture loads
from here, so adding one is a change to this dict and to the pinned artifacts it
implies, not a search through the tree.

Naming follows the module under `build/`: ARCH is the Debian architecture name
(`amd64`), CPU is the machine name (`x86_64`). The two are not interchangeable,
and which one a third party wants is not something to guess: Alpine and Bazel's
own `@platforms//cpu:` say `x86_64`, Docker and Debian say `amd64`, and LLVM
triples say `x86_64` again.

Only the native executable is architecture-specific. Everything else monobot
builds is a jar, and a jar is the same bytes everywhere.
"""

ARCH_CPU = {
    "amd64": "x86_64",
}

ARCHS = ARCH_CPU.keys()

# Target OS, shared by every supported arch. Named once so the per-arch
# `//platforms:is_<os>_<arch>` config_settings and the `@platforms//os:`
# constraint cannot drift apart.
OS = "linux"

def arch_select(values, default = None):
    """Build a platform-aware `select()` from `{arch_name: value}`.

    Keys on the per-arch `//platforms:is_<os>_<arch>` config_settings, each of
    which requires the OS constraint and the CPU constraint together, so a value
    is chosen only when both match.

    Args:
        values: Dict mapping Debian arch names to values.
        default: Optional fallback for `//conditions:default`.

    Returns:
        A `select()` keyed by the `//platforms:is_<os>_<arch>` config_settings.
    """
    select_ = {
        "//platforms:is_%s_%s" % (OS, arch): v
        for arch, v in values.items()
    }

    if default != None:
        select_["//conditions:default"] = default

    return select(select_)
