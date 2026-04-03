"""
Single source of truth for supported architectures and the facts derived from
them.

Every file that needs to iterate, select, or reference architectures loads from
here. No other file in the workspace should define its own arch list.

Naming: ARCH is the Debian architecture name (`amd64`, `arm64`); CPU is the
machine name (`x86_64`, `aarch64`). The OS (`linux`) is named here once so the
per-arch `//platforms:is_<os>_<arch>` config_settings and the `@platforms//os:`
constraint agree.
"""

ARCH_CPU = {
    "amd64": "x86_64",
    "arm64": "aarch64",
}

ARCHS = ARCH_CPU.keys()

# Target OS / kernel, shared by every supported arch. Named once so the per-arch
# `//platforms:is_<os>_<arch>` config_settings and the `@platforms//os:`
# constraint agree.
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
