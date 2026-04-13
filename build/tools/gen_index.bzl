"""Rule to generate the extension catalog index.json.

Pure Starlark: no external repo loads. Safe to use without triggering any source
or introspection fetches.
"""

# ---------------------------------------------------------------------------
# gen_index (build) + update_index (run)
# ---------------------------------------------------------------------------

def _parent_dir_name(f):
    """Extract the parent directory name from a file path."""
    return f.path.rsplit("/", 2)[-2]

def _gen_index_impl(ctx):
    index_json = {
        "contrib": sorted([_parent_dir_name(f) for f in ctx.files.contrib]),
        "extensions": sorted([
            _parent_dir_name(f)
            for f in ctx.files.extensions
        ]),
        "version": 1,
    }

    content = json.encode_indent(index_json, indent = "  ")

    ctx.actions.write(ctx.outputs.out, "%s\n" % content)

gen_index = rule(
    implementation = _gen_index_impl,
    attrs = {
        "contrib": attr.label_list(allow_files = [".json"]),
        "extensions": attr.label_list(allow_files = [".json"]),
        "out": attr.output(mandatory = True),
    },
)

def _update_index_impl(ctx):
    script = ctx.actions.declare_file(ctx.attr.name + ".sh")

    commands = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'dest="${BUILD_WORKSPACE_DIRECTORY}/%s"' % ctx.attr.dest,
        # --no-preserve=mode: Bazel marks all outputs executable; drop that so
        # copied files get default (0644) permissions.
        'cp --no-preserve=mode "%s" "${dest}"' % ctx.file.src.short_path,
        'echo "Updated ${dest}"',
    ]

    ctx.actions.write(script, "\n".join(commands), is_executable = True)

    runfiles = ctx.runfiles(files = [ctx.file.src])

    return [DefaultInfo(executable = script, runfiles = runfiles)]

update_index = rule(
    implementation = _update_index_impl,
    executable = True,
    attrs = {
        "dest": attr.string(
            mandatory = True,
            doc = "Workspace-relative destination path",
        ),
        "src": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Generated file to copy to source tree",
        ),
    },
)
