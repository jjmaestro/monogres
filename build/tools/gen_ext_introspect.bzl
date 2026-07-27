"""Regen + freshness for committed external-extension test introspects.

Each committed `catalog/extensions/<ext>/introspect/<ext>~<ver>.json` contains a
copy of the extension build's test-discovery output: the `<base>.tests.json`
side artifact of `@pg_ext//<ext>/<ver>/<base>:<base>` (produced by the build
running `make -n installcheck`; see `tools/ext_introspect.py`). The hub reads
the committed copy at load time so the extension test targets stay `bazel
query`-visible while the hub stays lazy.

These rules keep the committed copies honest:

- `update_ext_introspect` (`bazel run`): rebuild the representative base for
  each ext version and copy its emitted introspect back into the source tree.
- `check_ext_introspect` (`bazel test`): fail if any committed introspect drifts
  from what the build now discovers, so a Makefile / version change that alters
  the test universe cannot land without regenerating.

Both are driven by the catalog-derived `{ext: {ext_version: base_version}}`
manifest (`@pg_ext//:introspect.bzl`'s `TEST_INTROSPECTIONS`), whose base is the
representative build whose discovery is canonical for that ext version (the
newest minor of the only major that ext version supports).
"""

def _dest(ext, ext_version):
    return "catalog/extensions/%s/introspect/%s~%s.json" % (
        ext,
        ext,
        ext_version,
    )

def _emitted(ext, ext_version, base_version):
    return "@pg_ext//%s/%s/%s:%s.tests.json" % (
        ext,
        ext_version,
        base_version,
        base_version,
    )

def _committed(ext, ext_version):
    return "//catalog/extensions:%s/introspect/%s~%s.json" % (
        ext,
        ext,
        ext_version,
    )

# The main module's canonical repo name under Bzlmod; the runfiles root anchor
# from which both a main-repo `short_path` (`catalog/...`) and an external one
# (`../+monoext+pg_ext/...`) resolve.
_MAIN = "_main"

def _update_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    srcs = "\n".join(['  "%s"' % f.short_path for f in ctx.files.srcs])
    dests = "\n".join(['  "%s"' % d for d in ctx.attr.dests])
    ctx.actions.write(
        script,
        """\
#!/usr/bin/env bash
set -euo pipefail
base="${{RUNFILES_DIR:-${{0}}.runfiles}}/{main}"
srcs=(
{srcs}
)
dests=(
{dests}
)
for i in "${{!srcs[@]}}"; do
  cp --no-preserve=mode \\
    "${{base}}/${{srcs[i]}}" \\
    "${{BUILD_WORKSPACE_DIRECTORY}}/${{dests[i]}}"
  # Pin the committed copy to 0644 regardless of the caller's umask: it is
  # source data, never executable, and a stray exec bit would churn the tree.
  chmod 0644 "${{BUILD_WORKSPACE_DIRECTORY}}/${{dests[i]}}"
  echo "Updated ${{dests[i]}}"
done
""".format(main = _MAIN, srcs = srcs, dests = dests),
        is_executable = True,
    )
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = ctx.files.srcs),
    )]

_update_ext_introspect = rule(
    implementation = _update_impl,
    executable = True,
    attrs = {
        "dests": attr.string_list(mandatory = True),
        "srcs": attr.label_list(mandatory = True, allow_files = [".json"]),
    },
)

def _check_impl(ctx):
    committed = ctx.file.committed
    emitted = ctx.file.emitted
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        script,
        """\
#!/usr/bin/env bash
set -euo pipefail
cd "${{TEST_SRCDIR}}/${{TEST_WORKSPACE}}"
if ! diff -u "{committed}" "{emitted}"; then
  echo >&2
  echo "ERROR: committed {committed} is stale (the build now discovers a" >&2
  echo "different test universe). Regenerate it with:" >&2
  echo "  bazel run //catalog/extensions:update_ext_introspect" >&2
  exit 1
fi
echo "OK: {committed} matches the build's test discovery."
""".format(
            committed = committed.short_path,
            emitted = emitted.short_path,
        ),
        is_executable = True,
    )
    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [committed, emitted]),
    )]

_check_ext_introspect_test = rule(
    implementation = _check_impl,
    test = True,
    attrs = {
        "committed": attr.label(mandatory = True, allow_single_file = True),
        "emitted": attr.label(mandatory = True, allow_single_file = True),
    },
)

def ext_introspect(name, entries, check_name):
    """Wire the regen `bazel run` + per-entry freshness tests from the manifest.

    Args:
        name: name of the `bazel run` regen target.
        entries: `{ext: {ext_version: base_version}}` manifest; the base is the
            representative build whose discovery is canonical for that ext
            version (`@pg_ext//:introspect.bzl`'s `TEST_INTROSPECTIONS`).
        check_name: name of the `test_suite` gathering the freshness tests.
    """
    srcs = []
    dests = []
    checks = []
    for ext in sorted(entries):
        for ext_version in sorted(entries[ext]):
            base_version = entries[ext][ext_version]
            srcs.append(_emitted(ext, ext_version, base_version))
            dests.append(_dest(ext, ext_version))
            check = "check_%s~%s" % (ext, ext_version)
            checks.append(check)
            _check_ext_introspect_test(
                name = check,
                committed = _committed(ext, ext_version),
                emitted = _emitted(ext, ext_version, base_version),
                # Building the ext to re-discover is heavy, run explicitly or
                # via the named suite.
                tags = ["manual", "ext-introspect"],
            )
    _update_ext_introspect(name = name, srcs = srcs, dests = dests)
    native.test_suite(name = check_name, tests = checks, tags = ["manual"])
