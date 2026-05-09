"""
Rules for surfacing a sysroot package's directory as a make variable.

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

    template_vars = {ctx.attr.var: path}

    # Optional companion make-variables (e.g. the Debian multiarch tuple),
    # merged verbatim so consumers reach arch-specific lib subdirs as
    # `$($var)/lib/$(<name>)` / `$($var)/usr/lib/$(<name>)` without re-deriving
    # them from the sysroot tree at action time.
    template_vars.update(ctx.attr.vars)

    # Forward the sysroot filegroup's `DefaultInfo` so the on-disk tree lands in
    # the action's hermetic input set when a consumer takes a toolchains-attr
    # dep on this instance (or its arch-selecting alias). Without forwarding,
    # the action sees the make-variable path but the chroot has no files there.
    files = ctx.attr.target[DefaultInfo].files
    return [
        DefaultInfo(files = files),
        platform_common.TemplateVariableInfo(template_vars),
    ]

sysroot_dir = rule(
    implementation = _sysroot_dir_impl,
    doc = (
        "Expose a sysroot filegroup's execroot-relative package path as a " +
        "make variable. The variable is provided via `TemplateVariableInfo` " +
        "so consumers reach it through their `toolchains` attr; the " +
        "canonical bzlmod repo name is computed at analysis time and never " +
        "appears in human-authored source. Optional `vars` add companion " +
        "make variables (e.g. the Debian multiarch tuple) alongside it."
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
        "vars": attr.string_dict(
            default = {},
            doc = (
                "Optional companion make-variables merged verbatim into the " +
                "emitted `TemplateVariableInfo` (e.g. " +
                "`{\"LIBC_SYSROOT_MULTIARCH\": \"x86_64-linux-gnu\"}`). Lets " +
                "consumers reach arch-specific lib subdirs without " +
                "re-deriving them from the tree at action time."
            ),
        ),
    },
)

def _sysroot_exec_dir_impl(ctx):
    # `target` is resolved in EXEC config (`cfg = "exec"`), so the
    # `@platforms//cpu:*` select() inside the arch-selecting alias evaluates
    # against the EXEC platform's cpu, picking the host arch's sysroot
    # regardless of `--platforms` (which only affects TARGET resolution).
    info = ctx.attr.target[platform_common.TemplateVariableInfo]

    # Re-export every var the underlying `sysroot_dir` exposed under
    # `_EXEC_<SUFFIX>`-form names so consumers can reference both sides
    # (`$(LIBC_SYSROOT_DIR)` for target, `$(LIBC_SYSROOT_EXEC_DIR)` for exec,
    # etc.) within the same action.
    new_vars = {}
    for key, value in info.variables.items():
        prefix, _, suffix = key.rpartition("_")  # split LAST underscore
        if prefix:
            new_key = "%s_EXEC_%s" % (prefix, suffix)
        else:
            new_key = "EXEC_%s" % suffix
        new_vars[new_key] = value

    # Forward the underlying target's `DefaultInfo` files so the EXEC sysroot
    # tree lands in the action's hermetic input set when a consumer takes a
    # toolchains-attr dep on `:libc_sysroot_exec_dir`. Without this, the action
    # sees the `$(LIBC_SYSROOT_EXEC_DIR)` path in `LD_LIBRARY_PATH` but the
    # chroot has no files at that path; ld.so still fails.
    files = ctx.attr.target[DefaultInfo].files
    return [
        DefaultInfo(files = files),
        platform_common.TemplateVariableInfo(new_vars),
    ]

sysroot_exec_dir = rule(
    implementation = _sysroot_exec_dir_impl,
    doc = (
        "Sibling to `sysroot_dir`: re-exports the EXEC-config resolution of " +
        "an arch-selecting sysroot_dir alias, renaming each make variable to " +
        "its `<NAME>_EXEC` form. The `target` attr's " +
        "`cfg = 'exec'` forces the underlying select() to evaluate in EXEC " +
        "config, so the exposed dir is always the exec-host arch's sysroot " +
        "(regardless of `--platforms`). Lets actions reference both target " +
        "and exec sysroot dirs in the same `cmd` (e.g. `LD_LIBRARY_PATH` " +
        "for host tools + target -L paths)."
    ),
    attrs = {
        "target": attr.label(
            cfg = "exec",
            mandatory = True,
            providers = [platform_common.TemplateVariableInfo],
            doc = (
                "Arch-selecting `sysroot_dir` alias. Resolved in EXEC " +
                "config; the alias's `select()` picks the host arch's " +
                "sysroot_dir instance."
            ),
        ),
    },
)

def _exec_files_impl(ctx):
    # `target` is resolved in EXEC config (`cfg = "exec"`), so any
    # `@platforms//cpu:*` `select()` inside the referenced label evaluates
    # against the EXEC platform's cpu, picking the host arch's files regardless
    # of `--platforms` (which only affects TARGET resolution).
    return [DefaultInfo(files = ctx.attr.target[DefaultInfo].files)]

exec_files = rule(
    implementation = _exec_files_impl,
    doc = (
        "Forward a target's `DefaultInfo.files` resolved in EXEC config. " +
        "Use to surface an EXEC-arch copy of an arch-selecting filegroup / " +
        "alias (e.g. a per-PG `:sysroot_tar` whose `select()` is keyed by " +
        "`@platforms//cpu:*`) alongside the action's TARGET-config srcs. " +
        "The `cfg = 'exec'` attr forces the underlying `select()` to " +
        "evaluate in EXEC config so the emitted files are always the host " +
        "arch's. Action consumers `srcs`-dep both target and exec instances " +
        "to materialize parallel sysroot trees for tools that must run on " +
        "the build host (e.g. `msgfmt`, `bison`) while target libs / " +
        "headers come from the TARGET-config sysroot."
    ),
    attrs = {
        "target": attr.label(
            cfg = "exec",
            mandatory = True,
            allow_files = True,
            doc = (
                "Arch-selecting filegroup / alias whose files become this " +
                "rule's `DefaultInfo.files`. Resolved in EXEC config; the " +
                "underlying `select()` picks the host arch's files."
            ),
        ),
    },
)
