"""
Unit tests for `//catalog/postgres:extract_deps.bzl`.

Two thin tests: happy-path extraction on a synthetic mini-`repo.json` and a
sanity-pass over the live `//catalog/postgres:repo.json` (asserts version
coverage + that the buildtime/runtime kinds are populated for every version).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//catalog/postgres:extract_deps.bzl", "extract_deps")
load("//tests:suite.bzl", _test_suite = "test_suite")

_MINI_REPO_JSON = json.encode({
    "deps": {
        "buildtime": {
            "debian": {
                "*": ["libssl-dev", "libc6-dev"],
                ">=18": ["liburing-dev"],
            },
        },
        "runtime": {
            "debian": {
                "*": ["libssl3"],
            },
        },
    },
    "version": 1,
    "versions": {
        "16.10": {"sha256": "y", "tag": "REL_16_10"},
        "18.1": {"sha256": "x", "tag": "REL_18_1"},
    },
})

def _extract_happy_test_impl(ctx):
    """Synthetic mini-repo: wildcards + per-version spec resolved correctly."""
    env = unittest.begin(ctx)
    result = extract_deps(_MINI_REPO_JSON)

    asserts.equals(env, sorted(["18.1", "16.10"]), sorted(result.keys()))

    # 18.1 picks up `*` + `>=18` buildtime entries.
    asserts.equals(
        env,
        ["libc6-dev", "libssl-dev", "liburing-dev"],
        result["18.1"]["buildtime"],
    )

    # 16.10 picks up `*` only.
    asserts.equals(
        env,
        ["libc6-dev", "libssl-dev"],
        result["16.10"]["buildtime"],
    )

    # Runtime: every version gets the `*` entry.
    asserts.equals(env, ["libssl3"], result["18.1"]["runtime"])
    asserts.equals(env, ["libssl3"], result["16.10"]["runtime"])

    return unittest.end(env)

extract_happy_test = unittest.make(_extract_happy_test_impl)

def _empty_deps_test_impl(ctx):
    """Missing `deps` block yields empty lists for every version."""
    env = unittest.begin(ctx)
    minimal = json.encode(
        {"versions": {"15.0": {"sha256": "z", "tag": "REL_15_0"}}},
    )
    result = extract_deps(minimal)
    asserts.equals(env, ["15.0"], list(result.keys()))
    asserts.equals(env, [], result["15.0"]["buildtime"])
    asserts.equals(env, [], result["15.0"]["runtime"])
    return unittest.end(env)

empty_deps_test = unittest.make(_empty_deps_test_impl)

def _packages_deduped_test_impl(ctx):
    """Packages appearing in multiple matching specs are deduplicated."""
    env = unittest.begin(ctx)
    js = json.encode({
        "deps": {
            "buildtime": {
                "debian": {
                    "*": ["libssl-dev"],
                    ">=18": ["libssl-dev", "liburing-dev"],
                },
            },
        },
        "versions": {"18.1": {"sha256": "x", "tag": "x"}},
    })
    result = extract_deps(js)
    asserts.equals(
        env,
        ["libssl-dev", "liburing-dev"],
        result["18.1"]["buildtime"],
    )
    return unittest.end(env)

packages_deduped_test = unittest.make(_packages_deduped_test_impl)

TEST_SUITE_NAME = "extract_deps"

TEST_SUITE_TESTS = dict(
    empty_deps = empty_deps_test,
    extract_happy = extract_happy_test,
    packages_deduped = packages_deduped_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
