"""Copy the meson-captured config headers into the committed overlay seed.

The `:introspect` meson target captures the configured headers (pg_config.h,
pg_config_os.h, pg_config_ext.h, pg_config_paths.h) into a `config_headers` tree
(see `_CONFIG_HEADERS_CAPTURE` in `monoext/private/base/pg_build.bzl`). These
headers are produced by `meson setup` (feature detection plus the prefix_distro
paths), not by any build target, so they are absent from the introspect JSON:
they are the one residue the native cc_* Postgres overlay needs that the JSON
cannot carry.

`update_config_headers` copies that tree into
`build/catalog/<flavor>/config_headers/<flavor>~<v>~<opt>~<arch>/` so the
overlay consumes them as a committed seed, the same way the introspect JSONs are
committed. Pure shell via `BUILD_WORKSPACE_DIRECTORY`, mirroring `update_index`
in `gen_index.bzl`; the captured headers are stable (feature booleans plus
prefix_distro paths), so no path sanitization is required.
"""

# ---------------------------------------------------------------------------
# update_config_headers (run)
# ---------------------------------------------------------------------------

_CONFIG_HEADERS_DIR = "config_headers"

def _update_config_headers_impl(ctx):
    # The introspect target exposes the captured headers as a TreeArtifact named
    # `config_headers` in its default outputs (alongside `tar.json`).
    tree = None
    for f in ctx.files.introspect:
        if f.is_directory and f.basename == _CONFIG_HEADERS_DIR:
            tree = f
            break

    if tree == None:
        fail(
            "introspect target %s has no '%s' tree output; is the " +
            "_CONFIG_HEADERS_CAPTURE postfix wired into _pg_build_introspect?" %
            (ctx.attr.introspect.label, _CONFIG_HEADERS_DIR),
        )

    script = ctx.actions.declare_file(ctx.attr.name + ".sh")
    commands = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'dest="${BUILD_WORKSPACE_DIRECTORY}/%s"' % ctx.attr.dest,
        'rm -rf "${dest}"',
        'mkdir -p "${dest}"',
        # -L derefs (the tree files are plain copies); --no-preserve=mode drops
        # the executable bit Bazel stamps on outputs so headers land 0644.
        'cp -rL --no-preserve=mode "%s/." "${dest}/"' % tree.short_path,
        'echo "Updated ${dest}"',
    ]
    ctx.actions.write(script, "\n".join(commands), is_executable = True)

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [tree]),
    )]

update_config_headers = rule(
    implementation = _update_config_headers_impl,
    executable = True,
    doc = "Copy a :introspect target's captured config_headers tree into the " +
          "committed seed under build/catalog/<flavor>/config_headers/.",
    attrs = {
        "dest": attr.string(
            mandatory = True,
            doc = "Workspace-relative destination dir for the captured headers " +
                  "(e.g. catalog/postgres/config_headers/postgres~16.0~full~amd64).",
        ),
        "introspect": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "The :introspect meson target carrying the config_headers tree.",
        ),
    },
)
