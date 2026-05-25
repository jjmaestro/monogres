"""Macro that wires up the introspect-JSON normalizer.

The associated Python tool (`gen_pg_introspect_jsons.py`) walks its runfiles for
every `@<hub>//<v>/<os>:introspect` output and writes normalized copies into the
source tree under `build/catalog/<flavor>/introspect/`. It is instantiated once
per flavor hub (`pg`/postgres, `ivory`/ivorysql, …). It also reads each
test-enabled build variant introspect (`@<hub>//<v>/<os>/test:introspect`,
tap_tests on) and writes it beside the production sibling as
`<flavor>~<v>~<os>+test.json`, the introspect that drives the test lane.

The caller enumerates the `(version, option_set)` matrix from the hub's
`all.bzl` and passes it in, so Bazel builds every introspect target as a
prerequisite of `bazel run` (no `bazel query | xargs bazel build` needed).

Introspect targets are tagged `manual`, so we mark the generated `py_binary`
manual too: it stays out of wildcard expansions (`bazel build //...`) by default
but is callable explicitly.
"""

load("@rules_python//python:py_binary.bzl", "py_binary")

def gen_pg_introspect_jsons(
        name,
        hub,
        flavor,
        versions,
        option_sets,
        test_versions = None):
    """Wire the introspect-JSON normalizer for one flavor hub.

    Args:
        name: target name of the generated `py_binary`.
        hub: monogres hub repo name (e.g. `"pg"`, `"ivory"`).
        flavor: catalog flavor (e.g. `"postgres"`, `"ivorysql"`).
        versions: every version to introspect (the production `introspect/`
            catalog).
        option_sets: option sets to introspect per version.
        test_versions: subset of `versions` that also feeds the test-enabled
            `+test` introspect variant (default all of `versions`). Each flavor
            hub passes its full VERSIONS, so every version gets a `+test`
            variant.
    """
    if test_versions == None:
        test_versions = versions

    # `--src <v>=<runfiles path>` hands the tool each version's source tree (the
    # per-version `:dir` alias), used to walk `contrib/*/<*.control>` and bake
    # per-contrib `requires` into the generated JSONs.
    src_args = []
    for v in versions:
        src_args.extend([
            "--src",
            "{v}=$(rlocationpath @{hub}//{v}:dir)".format(hub = hub, v = v),
        ])

    py_binary(
        name = name,
        srcs = ["gen_pg_introspect_jsons.py"],
        main = "gen_pg_introspect_jsons.py",
        args = ["--hub", hub, "--flavor", flavor] + src_args,
        data = [
            "@{hub}//{v}/{os}:introspect".format(hub = hub, v = v, os = os)
            for v in versions
            for os in option_sets
        ] + [
            # The test-enabled build variant's introspect (tap_tests on, plus
            # injection_points where the version supports it). The tool writes
            # it into the `+test` introspect variant the test lane reads; the
            # production introspect stays tap-disabled.
            "@{hub}//{v}/{os}/test:introspect".format(hub = hub, v = v, os = os)
            for v in test_versions
            for os in option_sets
        ] + [
            "@{hub}//{v}:dir".format(hub = hub, v = v)
            for v in versions
        ],
        tags = ["manual"],
    )
