"""
Custom platform transition for explicit per-arch builds.

`platform_build` wraps a target and forces it to build under a specific
`--platforms` value.
"""

def _arch_transition_impl(_, attr):
    return {"//command_line_option:platforms": attr.platform}

_arch_transition = transition(
    implementation = _arch_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _platform_build_impl(ctx):
    target = ctx.attr.actual[0]
    providers = [target[DefaultInfo]]

    if OutputGroupInfo in target:
        providers.append(target[OutputGroupInfo])

    return providers

platform_build = rule(
    implementation = _platform_build_impl,
    doc = """
    Force a target to build under a specific platform.

    Wraps `actual` with a platform transition so the dependency graph beneath
    it is compiled for the architecture given by `platform`. Both `DefaultInfo`
    and `OutputGroupInfo` are forwarded from the transitioned target.

    Unlike `platform_transition_filegroup` from bazel_skylib, this rule
    preserves `OutputGroupInfo`, which is needed by consumers that read output
    groups (e.g. introspect JSON, installed-file manifests).
    """,
    attrs = {
        "actual": attr.label(
            cfg = _arch_transition,
            mandatory = True,
            doc = "The target to rebuild under the specified platform.",
        ),
        "platform": attr.string(
            mandatory = True,
            doc = """
            Fully-qualified platform label (e.g. `//platforms:linux_arm64`).
            """,
        ),
    },
)
