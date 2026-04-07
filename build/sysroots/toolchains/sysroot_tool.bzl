"""Generic Bazel toolchain helpers for tools sourced from `sysroots.apt(...)`
    hubs.

Lets a consumer (e.g. `//toolchains/perl`) wrap a single binary inside a sysroot
hub as a proper Bazel toolchain in the same shape that `rules_m4`, `rules_flex`,
`rules_bison` use:

  * `<lang>_toolchain` instance(s) per arch, registered via the project's
    `register_toolchains(...)`.
  * A `:current_<lang>_toolchain` resolver that picks the right per-arch
    instance at action exec config and exposes `TemplateVariableInfo` plus
    `ToolchainInfo`. Goes in `toolchains = [...]` of consuming rules.
  * A `:<lang>` binary label (per-arch alias by the consumer) addressable
    like `@bison//bin:bison`. Goes in `build_data`-style lists.

This module provides:

  * `SysrootToolInfo`: provider exposing the binary `File`, the depset of
    files needed to run it (libs, modules, etc.), an `env_var` name (the
    `TemplateVariableInfo` key the resolver should emit), a `version` string,
    and a free-form `extra` `string_dict` for tool-specific metadata.
  * `sysroot_tool`: rule producing a `ToolchainInfo` wrapping
    `SysrootToolInfo`. Per-arch instance shape; also returns `DefaultInfo`
    pointing at the binary with the broader runtime tree as runfiles so the same
    target serves directly as the `:<lang>` binary (when reached via per-arch
    alias).
  * `make_current_sysroot_tool`: factory returning a `current_<lang>_toolchain`
    rule for a given `toolchain_type` label. The returned rule resolves the
    registered toolchain at action exec config and exposes the tool's
    `TemplateVariableInfo` plus the same `ToolchainInfo` / `SysrootToolInfo`
    re-emitted from the resolved instance. No `DefaultInfo` files (to avoid
    duplicate-target errors when both the resolver and the per-arch binary are
    reached through the same consumer rule's data dependencies).

Consumer pattern (see `//toolchains/perl` for the worked example):

```python
load("@sysroots//toolchains:sysroot_tool.bzl", "sysroot_tool", "make_current_sysroot_tool")

toolchain_type(name = "toolchain_type")

sysroot_tool(
    name = "perl_amd64_impl",
    binary = "@perl_sysroot//debian/12/amd64:usr/bin/perl",
    runtime = "@perl_sysroot//debian/12/amd64:sysroot",
    env_var = "PERL",
    vars = {"MULTIARCH": "x86_64-linux-gnu"},
    version = "5.36",
)

toolchain(
    name = "perl_amd64",
    target_compatible_with = ["@platforms//cpu:x86_64"],
    toolchain = ":perl_amd64_impl",
    toolchain_type = ":toolchain_type",
)

# Resolver rule for the active perl toolchain (factory + instance):
current_perl_toolchain = make_current_sysroot_tool(":toolchain_type")
current_perl_toolchain(name = "current_perl_toolchain")

# Per-arch alias to the binary instance (mirrors @bison//bin:bison shape):
alias(
    name = "perl",
    actual = select({
        "@platforms//cpu:x86_64": ":perl_amd64_impl",
        ...
    }),
)
```

Each `vars` entry `{suffix: value}` reaches consumers as a
`$(<env_var>_<suffix>)` make-variable via the resolver's `TemplateVariableInfo`
(so `env_var = "PERL"` plus `vars = {"MULTIARCH": ...}` emits `PERL_MULTIARCH`).
The value is opaque to this generic helper. A tool materialized from a per-arch
Debian hub passes that hub's multiarch tuple, so consumers can expand
`<env_var>`-side paths (e.g. `PERL5LIB`) against the tool's OWN lib dir (always
exec arch), independent of the build's TARGET arch. Foundational for
cross-compile.

The two-step factory (function-returning-rule, then instantiate with `name`) is
required because `rule(toolchains = [...])` is a config-time argument that has
to be baked into the rule definition. The factory closes over the
`toolchain_type` label so the resolver knows which type to look up.
"""

SysrootToolInfo = provider(
    doc = (
        "A tool binary sourced from a sysroot hub, plus the runtime context " +
        "(libs, modules) needed to invoke it inside a hermetic action sandbox."
    ),
    fields = {
        "binary": "Tool binary `File`.",
        "env_var": (
            "Make-variable name the resolver emits via " +
            "`TemplateVariableInfo` (e.g. `\"PERL\"`)."
        ),
        "files": (
            "depset of every `File` needed to invoke the binary: the binary " +
            "itself plus its dynamic-link deps and any runtime data (perl " +
            "lib tree, python stdlib, etc.)."
        ),
        "vars": (
            "Companion make-variables for this per-arch instance, keyed by " +
            "suffix. The `make_current_sysroot_tool` resolver emits each " +
            "`{suffix: value}` as a `<env_var>_<suffix>` " +
            "`TemplateVariableInfo` key (e.g. `{\"MULTIARCH\": ...}` -> " +
            "`PERL_MULTIARCH`). The value is opaque here; a consumer that " +
            "materialized the tool from a per-arch Debian hub passes that " +
            "hub's tuple, so downstream consumers can expand " +
            "interpreter-side paths against the TOOL'S arch (always exec " +
            "arch) independently of the build's TARGET arch (per " +
            "`@platforms//cpu:*`). Empty for tools with no companion vars."
        ),
        "version": "Tool version string (e.g. `\"5.36\"`).",
    },
)

def _sysroot_tool_impl(ctx):
    files = depset(ctx.files.runtime)
    tool = SysrootToolInfo(
        binary = ctx.file.binary,
        files = files,
        env_var = ctx.attr.env_var,
        vars = ctx.attr.vars,
        version = ctx.attr.version,
    )
    return [
        platform_common.ToolchainInfo(tool = tool),
        tool,
        DefaultInfo(
            files = depset([ctx.file.binary]),
            runfiles = ctx.runfiles(transitive_files = files),
        ),
    ]

sysroot_tool = rule(
    doc = (
        "Declares a tool toolchain backed by a sysroot hub. `binary` is the " +
        "single-file label that the hub `exports_files`-exposes (typically " +
        "via the hub's `exports = [...]` attr); `runtime` is the broader " +
        "filegroup (typically the hub's `:sysroot` filegroup) carrying the " +
        "binary's runtime context. The same target acts as the per-arch " +
        "binary alias target: its `DefaultInfo` is the binary itself with " +
        "the runtime tree as runfiles."
    ),
    implementation = _sysroot_tool_impl,
    attrs = {
        "binary": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = (
                "Tool binary label, e.g. " +
                "`@perl_sysroot//debian/12/amd64:usr/bin/perl` (made " +
                "addressable by the hub's `exports = [\"usr/bin/perl\"]`)."
            ),
        ),
        "env_var": attr.string(
            mandatory = True,
            doc = (
                "Make-variable name for `$(<env_var>)` substitution emitted " +
                "by the resolver (e.g. `\"PERL\"`)."
            ),
        ),
        "runtime": attr.label(
            mandatory = True,
            allow_files = True,
            doc = (
                "Filegroup carrying the runtime context. Typically the " +
                "hub's `:sysroot` filegroup; the binary plus this filegroup " +
                "are what land in the action sandbox at consumption time."
            ),
        ),
        "vars": attr.string_dict(
            default = {},
            doc = (
                "Companion make-variables keyed by suffix. Each " +
                "`{suffix: value}` is emitted by the resolver as a " +
                "`<env_var>_<suffix>` `TemplateVariableInfo` key (e.g. " +
                "`{\"MULTIARCH\": ...}` -> `PERL_MULTIARCH`). The value is " +
                "opaque to this generic rule."
            ),
        ),
        "version": attr.string(
            default = "",
            doc = "Tool version string (e.g. `\"5.36\"`).",
        ),
    },
)

def make_current_sysroot_tool(toolchain_type):
    """Factory for a `current_<tool>_toolchain`-style resolver rule.

    Args:
        toolchain_type: `Label` of the `toolchain_type` to resolve, e.g.
            `Label(\"//toolchains/perl:toolchain_type\")`. MUST be a `Label`
            object (not a string) so its repo context is captured at call time;
            the factory lives in `@sysroots` and the toolchain_type is typically
            declared in the calling module, so a bare string would resolve
            against `@sysroots` and miss the calling module's mapping.

    Returns:
        A `rule()` callable. Instantiate it in a `BUILD.bazel` as
        `current_<tool>_toolchain(name = \"current_<tool>_toolchain\")`. The
        instance returns `TemplateVariableInfo({env_var: binary.path, ...})`,
        the `ToolchainInfo` from the resolved instance, and the underlying
        `SysrootToolInfo` so direct dep consumers can read `.binary`, `.files`,
        `.version`, etc. Each of the resolved instance's `vars` entries
        `{suffix: value}` is emitted as an `<env_var>_<suffix>` make-variable
        alongside `env_var` itself. Those reflect the TOOL's arch (always exec
        arch under standard toolchain resolution), independent of the build's
        TARGET arch per `@platforms//cpu:*`. Lets consumers expand
        interpreter-side paths (e.g. `PERL5LIB`'s perl-base / perl/<ver>)
        against the TOOL's own lib dir while target-arch paths come from a
        separate sysroot. Foundational for cross-compile readiness.
    """

    def _impl(ctx):
        toolchain = ctx.toolchains[toolchain_type]
        tool = toolchain.tool
        template_vars = {tool.env_var: tool.binary.path}
        for suffix, value in tool.vars.items():
            template_vars["%s_%s" % (tool.env_var, suffix)] = value
        return [
            toolchain,
            tool,
            platform_common.TemplateVariableInfo(template_vars),
        ]

    return rule(
        doc = (
            "Resolves the registered sysroot-backed toolchain at the " +
            "action's exec configuration and exposes its " +
            "`SysrootToolInfo.env_var` -> binary path via " +
            "`TemplateVariableInfo`, suitable for the `toolchains = [...]` " +
            "list of `rules_foreign_cc.meson()` (and similar)."
        ),
        implementation = _impl,
        toolchains = [toolchain_type],
    )
