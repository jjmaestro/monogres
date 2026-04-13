"""Rule to generate contrib extension repo.json files."""

# ---------------------------------------------------------------------------
# gen_contrib (macro + rule) + update_contrib (run)
# ---------------------------------------------------------------------------

def _get_contrib_data(introspections, option_set):
    """Extract {ext_name: {pg_version: [files]}} from introspections."""
    all_contribs = {}

    for key, introspection in introspections.items():
        pg_version, opt_set = key
        if opt_set != option_set:
            continue

        for name, data in introspection["contrib"].items():
            if name not in all_contribs:
                all_contribs[name] = {}
            all_contribs[name][pg_version] = data["paths"]

    return all_contribs

def _gen_contrib_repo_json(versions_data):
    """Build the repo.json content string for one contrib extension."""
    sorted_versions = sorted(versions_data.keys())

    repo_json = {
        "kind": "contrib",
        "metadata": {
            "files": {v: versions_data[v] for v in sorted_versions},
        },
        "version": 1,
        "versions": sorted_versions,
    }

    return json.encode_indent(repo_json, indent = "  ")

def _gen_contrib_impl(ctx):
    contribs = json.decode(ctx.attr.contribs_json)
    outputs = []

    for name in sorted(contribs):
        repo_json = "%s/%s/repo.json" % (ctx.attr.name, name)
        content = _gen_contrib_repo_json(contribs[name])

        out = ctx.actions.declare_file(repo_json)
        ctx.actions.write(out, "%s\n" % content, is_executable = False)
        outputs.append(out)

    return [DefaultInfo(files = depset(outputs))]

_gen_contrib = rule(
    implementation = _gen_contrib_impl,
    attrs = {
        "contribs_json": attr.string(
            mandatory = True,
            doc = "JSON-encoded {ext_name: {pg_version: [paths]}} contrib data",
        ),
    },
)

def gen_contrib(name, introspections, option_set = "full"):
    """Generate contrib extension repo.json files.

    Args:
        name: rule target name.
        introspections: INTROSPECTIONS dict from @pg//:introspect.bzl.
        option_set: option set to filter by (default "full").
    """
    contribs = _get_contrib_data(introspections, option_set)
    _gen_contrib(name = name, contribs_json = json.encode(contribs))

def _update_contrib_impl(ctx):
    script = ctx.actions.declare_file(ctx.attr.name + ".sh")

    # $BUILD_WORKSPACE_DIRECTORY is set by `bazel run`
    commands = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'dest="${BUILD_WORKSPACE_DIRECTORY}/%s"' % ctx.attr.dest,
        'echo "Updating ${dest} ..."',
    ]

    for f in ctx.files.srcs:
        # f.short_path is like
        # "catalog/extensions/gen_contrib/pgcrypto/repo.json" we want
        # "pgcrypto/repo.json" (relative to gen target)
        rel = "/".join(f.short_path.split("/")[3:])
        commands.append('mkdir -p "${dest}/%s"' % rel.rsplit("/", 1)[0])

        # --no-preserve=mode: Bazel marks all outputs executable; drop that so
        # copied files get default (0644) permissions.
        commands.append(
            'cp --no-preserve=mode "%s" "${dest}/%s"' % (f.short_path, rel),
        )

    commands.append(
        'echo "Done: $(ls "${dest}" | wc -l) contrib extensions"',
    )

    ctx.actions.write(script, "\n".join(commands), is_executable = True)

    runfiles = ctx.runfiles(files = ctx.files.srcs)

    return [DefaultInfo(executable = script, runfiles = runfiles)]

update_contrib = rule(
    implementation = _update_contrib_impl,
    executable = True,
    attrs = dict(
        srcs = attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "Generated contrib repo.json files",
        ),
        dest = attr.string(
            mandatory = True,
            doc = "Workspace-relative destination directory",
        ),
    ),
)
