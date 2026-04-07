"""
Rule for surfacing a sysroot package's directory as a make variable.

`sysroots.apt(...)`-materialized hubs live at canonical bzlmod paths like
`external/sysroots++sysroots+<name>/<distro>/<version>/<arch>/`. Consumers (e.g.
`pgxs_build.bzl`) that need the directory path as a string at action time would
otherwise have to hardcode the canonical name, which couples project source to
Bazel's repo-mapping mechanics.

`sysroot_dir` wraps a sysroot filegroup label and emits a `TemplateVariableInfo`
whose value is the label's execroot-relative package path, derived from
`label.workspace_name + label.package` at analysis time. Consumers list the
target in their `toolchains` attr and reference the variable in `cmd`:

    sysroot_dir(
        name = "llvm_sysroot_dir_amd64", target =
        "@llvm_sysroot//debian/12/amd64:sysroot", var = "LLVM_SYSROOT_DIR",
    )

    genrule(
        ... toolchains = [":llvm_sysroot_dir_amd64"], cmd = "ls
        $(LLVM_SYSROOT_DIR)/usr/lib/llvm-<V>/bin/llvm-lto",
    )

Per-arch instances + an arch-selecting `alias(... select(...))` cover
cross-compile combinations without per-consumer dispatch logic.
"""

def _sysroot_dir_impl(ctx):
    label = ctx.attr.target.label

    # External repos resolve to `external/<canonical_workspace_name>/<package>`;
    # main-repo targets resolve to just `<package>` (or empty for the root).
    if label.workspace_name:
        path = "external/%s/%s" % (label.workspace_name, label.package)
    else:
        path = label.package

    return [
        DefaultInfo(),
        platform_common.TemplateVariableInfo({ctx.attr.var: path}),
    ]

sysroot_dir = rule(
    implementation = _sysroot_dir_impl,
    doc = (
        "Expose a sysroot filegroup's execroot-relative package path as a " +
        "make variable. The variable is provided via `TemplateVariableInfo` " +
        "so consumers reach it through their `toolchains` attr; the " +
        "canonical bzlmod repo name is computed at analysis time and never " +
        "appears in human-authored source."
    ),
    attrs = {
        "target": attr.label(
            mandatory = True,
            doc = (
                "Sysroot filegroup label whose package path becomes the var " +
                "value (e.g. `@<hub>//<distro>/<version>/<arch>:sysroot`)."
            ),
        ),
        "var": attr.string(
            mandatory = True,
            doc = "Make-variable name (e.g. `LLVM_SYSROOT_DIR`).",
        ),
    },
)
