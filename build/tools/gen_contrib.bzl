"""Rule to generate contrib extension repo.json files."""

# ---------------------------------------------------------------------------
# gen_contrib (macro + rule) + update_contrib (run)
# ---------------------------------------------------------------------------

def _get_contrib_data(introspections_list, option_set):
    """[INTROSPECTIONS, ...] -> {ext_name: {"files": ..., "requires": ...}}

    Each list element is one flavor's `@<hub>//:introspect.bzl` INTROSPECTIONS
    dict; the flavor is read from each entry's `introspection["flavor"]` (which
    `base/introspect.bzl` renders into the data), so the flavor is
    self-described rather than supplied as a caller-side dict key.

    Returns a dict keyed by contrib name, each value containing:
      - `files`: `{flavor: {base_v: [paths]}}` — installed paths per
        (flavor, base_v); always populated.
      - `requires`: `{flavor: {base_v: [reqs]}}` — install-time PG-extension
        dependencies parsed from `.control` files at JSON-generation time (see
        `tools/gen_pg_introspect_jsons.py`); entries are omitted when empty (the
        underlying `INTROSPECTION` skips the key).
    """
    all_contribs = {}

    for introspections in introspections_list:
        for key, introspection in introspections.items():
            base_version, opt_set = key
            if opt_set != option_set:
                continue

            flavor = introspection["flavor"]
            for name, data in introspection["contrib"].items():
                if name not in all_contribs:
                    all_contribs[name] = {"files": {}, "requires": {}}
                if flavor not in all_contribs[name]["files"]:
                    all_contribs[name]["files"][flavor] = {}
                    all_contribs[name]["requires"][flavor] = {}
                all_contribs[name]["files"][flavor][base_version] = data["paths"]
                requires = data.get("requires", [])
                if requires:
                    all_contribs[name]["requires"][flavor][base_version] = requires

    return all_contribs

def _parse_pgver(v_str):
    """Parse a PGVER `major.minor` string into a (major, minor) tuple of ints.

    Returns `None` if the string isn't shaped like one. Used by
    `_collapse_pgver` for boundary detection (major-version breaks).
    """
    parts = v_str.split(".")
    if len(parts) != 2:
        return None
    if not parts[0].isdigit() or not parts[1].isdigit():
        return None
    return (int(parts[0]), int(parts[1]))

def _collapse_pgver(per_base_v_requires):
    """Collapse {base_v: [reqs]} (PGVER) to {spec: [reqs]} via range detection.

    Sort base_v values numerically. Walk linearly; group adjacent versions with
    identical requires. For each group, emit the tightest spec that covers it
    cleanly at PG-major boundaries:

      - If all base_v in the flavor produce the same list → `"*"`.
      - If groups split cleanly on PG-major boundaries (e.g. all 16.* one
        list, all 17.* another) → `"<17"` + `">=17"`, or `">=16, <18"` for a
        middle group bounded on both sides.
      - Otherwise (non-contiguous or non-major-aligned splits): fall back
        to per-base_v exact spec keys.

    Versions that don't parse as PGVER fall back to exact keys too.
    """
    if not per_base_v_requires:
        return {}

    parsed = {v: _parse_pgver(v) for v in per_base_v_requires}
    if None in parsed.values():
        # Some non-PGVER versions present; fall back to exact keys.
        return {
            v: sorted(per_base_v_requires[v])
            for v in sorted(per_base_v_requires)
        }

    sorted_vs = sorted(per_base_v_requires, key = lambda v: parsed[v])

    # Group contiguous runs that share the same requires list.
    groups = []
    for v in sorted_vs:
        reqs = sorted(per_base_v_requires[v])
        reqs_key = json.encode(reqs)
        if groups and groups[-1]["reqs_key"] == reqs_key:
            groups[-1]["end"] = v
        else:
            groups.append(
                {"end": v, "reqs": reqs, "reqs_key": reqs_key, "start": v},
            )

    if len(groups) == 1:
        return {"*": groups[0]["reqs"]}

    # Try to express each group's bounds at major boundaries.
    result = {}
    use_exact_fallback = False
    for i, g in enumerate(groups):
        start_major = parsed[g["start"]][0]
        end_major = parsed[g["end"]][0]
        prev = groups[i - 1] if i > 0 else None
        nxt = groups[i + 1] if i + 1 < len(groups) else None

        # Group is clean only if its major range is contiguous AND the adjacent
        # groups start/end exactly at adjacent majors.
        right_clean = nxt == None or parsed[nxt["start"]][0] == end_major + 1
        left_clean = prev == None or parsed[prev["end"]][0] == start_major - 1
        if not (left_clean and right_clean):
            use_exact_fallback = True
            break

        if prev == None and nxt == None:
            spec = "*"
        elif prev == None:
            spec = "<%d" % parsed[nxt["start"]][0]
        elif nxt == None:
            spec = ">=%d" % start_major
        else:
            spec = ">=%d, <%d" % (start_major, parsed[nxt["start"]][0])
        result[spec] = g["reqs"]

    if use_exact_fallback:
        return {
            v: sorted(per_base_v_requires[v])
            for v in sorted(per_base_v_requires)
        }

    return result

def _emit_requires_per_spec(requires_by_flavor):
    """Build the catalog `metadata.requires` dict.

    Shape: {flavor: {spec: [reqs]}}. Flavors with no non-empty requires are
    omitted. Per-flavor, applies `_collapse_pgver` to collapse contiguous
    PG-major runs to range specs.
    """
    out = {}
    for flavor in sorted(requires_by_flavor):
        non_empty = {
            bv: reqs
            for bv, reqs in requires_by_flavor[flavor].items()
            if reqs
        }
        if not non_empty:
            continue
        out[flavor] = _collapse_pgver(non_empty)
    return out

def _gen_contrib_repo_json(contrib_data):
    """Render one contrib's repo.json from collected files + requires."""
    files_by_flavor = contrib_data["files"]
    sorted_flavors = sorted(files_by_flavor.keys())

    metadata = {
        "files": {
            f: {
                bv: files_by_flavor[f][bv]
                for bv in sorted(files_by_flavor[f].keys())
            }
            for f in sorted_flavors
        },
    }

    requires = _emit_requires_per_spec(contrib_data.get("requires", {}))
    if requires:
        metadata["requires"] = requires

    repo_json = {
        "kind": "contrib",
        "metadata": metadata,
        "version": 1,
        "versions": {
            f: sorted(files_by_flavor[f].keys())
            for f in sorted_flavors
        },
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
            doc = "JSON-encoded {ext_name: {\"files\": {flavor: {base_v: [paths]}}, " +
                  "\"requires\": {flavor: {base_v: [reqs]}}}} contrib data",
        ),
    },
)

def gen_contrib(name, introspections, option_set = "full"):
    """Generate contrib extension repo.json files.

    Reads Layer 1's `INTROSPECTIONS` aggregator: each entry's
    `INTROSPECTION["contrib"][name]` carries installed `paths` and an optional
    `requires` list. The `requires` data is baked into the committed introspect
    JSONs at generation time by `tools/gen_pg_introspect_jsons.py` (which walks
    the source tree's `.control` files), so this consumer needs no source
    download.

    Args:
        name: rule target name.
        introspections: list of INTROSPECTIONS dicts (from each
            `@<hub>//:introspect.bzl`), one per base flavor. Each entry's
            `introspection["flavor"]` identifies the flavor, so no caller-side
            flavor keys are needed.
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
