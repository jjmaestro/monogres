"""
Architectures supported by `//sysroots`.

The `apt` tag class accepts `archs` as an explicit arg from the caller, so the
extension does not require this list at module-extension time. The list is still
useful as a default for callers that want to materialize every supported arch,
and for `arch_select()` consumers that build per-arch `select()`s in generated
`BUILD.bazel` files.
"""

ARCH_CPU = {
    "amd64": "x86_64",
    "arm64": "aarch64",
}

ARCHS = ARCH_CPU.keys()

def arch_select(values, default = None):
    """Build a platform-aware `select()` from `{arch_name: value}`.

    Args:
        values: Dict mapping Debian arch names (`amd64`, `arm64`) to values.
        default: Optional fallback for `//conditions:default`.

    Returns:
        A `select()` keyed by `@platforms//cpu:*` constraint values.
    """
    select_ = {
        "@platforms//cpu:%s" % ARCH_CPU[arch]: v
        for arch, v in values.items()
    }

    if default != None:
        select_["//conditions:default"] = default

    return select(select_)
