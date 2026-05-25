"""Macro that wires up the introspect-JSON normalizer.

The associated Python tool (`gen_pg_introspect_jsons.py`) walks its runfiles for
every `@pg//<v>/<os>:introspect` output and writes normalized copies into the
source tree under `build/catalog/postgres/introspect/`. It also reads each
test-enabled build variant introspect (`@pg//<v>/<os>/test:introspect`,
tap_tests on) and writes it beside the production sibling as
`postgres~<v>~<os>+test.json`, the introspect that drives the test lane.

We enumerate the `(version, option_set)` matrix at BUILD-load time from
`@pg//:all.bzl` (already used by `//build/examples/private/base:BUILD.bazel`),
which makes Bazel responsible for building every introspect target as a
prerequisite of `bazel run` — no `bazel query | xargs bazel build` needed.

Introspect targets are tagged `manual`, so we mark the generated `py_binary`
manual too: it stays out of wildcard expansions (`bazel build //...`) by default
but is callable explicitly.
"""

load("@pg//:all.bzl", "OPTION_SETS", "VERSIONS")
load("@rules_python//python:py_binary.bzl", "py_binary")

def gen_pg_introspect_jsons(name):
    py_binary(
        name = name,
        srcs = ["gen_pg_introspect_jsons.py"],
        main = "gen_pg_introspect_jsons.py",
        data = [
            "@pg//{v}/{os}:introspect".format(v = v, os = os)
            for v in VERSIONS
            for os in OPTION_SETS
        ] + [
            # The test-enabled build variant's introspect (tap_tests on, plus
            # injection_points where the version supports it). The tool writes
            # it into the `+test` introspect variant the test lane reads; the
            # production introspect stays tap-disabled.
            "@pg//{v}/{os}/test:introspect".format(v = v, os = os)
            for v in VERSIONS
            for os in OPTION_SETS
        ],
        tags = ["manual"],
    )
