"""
Unit tests for //sysroots/apt/private:closure.bzl.

Exercises the per-arch transitive-closure walker against lockfile-shaped
fixtures: simple transitive deps, diamond DAGs, cycles, unknown names, and
asymmetric per-arch graphs.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//apt/private:closure.bzl", "closure", "testing")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _pkg(name, arch, dependencies = []):
    """Build a minimal package-shaped dict for the closure walker.

    Args:
        name: Package name.
        arch: Architecture.
        dependencies: List of `{name, ...}` dep dicts.

    Returns:
        Dict matching the lockfile's per-package shape (subset relevant to the
        walker: `name`, `arch`, `dependencies`).
    """
    return {
        "arch": arch,
        "dependencies": dependencies,
        "key": "%s_%s" % (name, arch),
        "name": name,
        "sha256": "0" * 64,
        "urls": ["https://example.invalid/%s" % name],
        "version": "1.0",
    }

def _dep(name):
    return {"key": "%s_amd64" % name, "name": name, "version": "1.0"}

def _index_by_arch_groups_packages_test_impl(ctx):
    """`_index_by_arch` buckets packages by arch and indexes by name."""
    env = unittest.begin(ctx)

    packages = [
        _pkg("libc6", "amd64"),
        _pkg("libc6", "arm64"),
        _pkg("libssl", "amd64"),
    ]

    indexed = testing._index_by_arch(packages)

    asserts.equals(env, sorted(indexed.keys()), ["amd64", "arm64"])
    asserts.equals(env, sorted(indexed["amd64"].keys()), ["libc6", "libssl"])
    asserts.equals(env, sorted(indexed["arm64"].keys()), ["libc6"])
    asserts.equals(env, indexed["amd64"]["libc6"]["arch"], "amd64")

    return unittest.end(env)

index_by_arch_groups_packages_test = unittest.make(
    _index_by_arch_groups_packages_test_impl,
)

def _closure_walks_transitive_deps_test_impl(ctx):
    """Closure walks one level of deps and pulls them in."""
    env = unittest.begin(ctx)

    by_name = {
        "libc6": _pkg("libc6", "amd64"),
        "libc6-dev": _pkg("libc6-dev", "amd64", dependencies = [_dep("libc6")]),
        "libssl-dev": _pkg(
            "libssl-dev",
            "amd64",
            dependencies = [_dep("libssl3"), _dep("libc6-dev")],
        ),
        "libssl3": _pkg("libssl3", "amd64", dependencies = [_dep("libc6")]),
    }

    result = testing._closure_for_arch(by_name, ["libssl-dev"])

    names = [p["name"] for p in result]
    asserts.equals(env, names, ["libc6", "libc6-dev", "libssl-dev", "libssl3"])

    return unittest.end(env)

closure_walks_transitive_deps_test = unittest.make(
    _closure_walks_transitive_deps_test_impl,
)

def _closure_handles_diamond_dep_test_impl(ctx):
    """Diamond dep graph: same leaf reached via two paths is included once."""
    env = unittest.begin(ctx)

    by_name = {
        "leaf": _pkg("leaf", "amd64"),
        "left": _pkg("left", "amd64", dependencies = [_dep("leaf")]),
        "right": _pkg("right", "amd64", dependencies = [_dep("leaf")]),
        "top": _pkg(
            "top",
            "amd64",
            dependencies = [_dep("left"), _dep("right")],
        ),
    }

    result = testing._closure_for_arch(by_name, ["top"])

    names = [p["name"] for p in result]
    asserts.equals(env, names, ["leaf", "left", "right", "top"])
    asserts.equals(env, len(result), 4)

    return unittest.end(env)

closure_handles_diamond_dep_test = unittest.make(
    _closure_handles_diamond_dep_test_impl,
)

def _closure_handles_cycle_test_impl(ctx):
    """Cyclic dep graph: walker terminates and includes every reachable node."""
    env = unittest.begin(ctx)

    by_name = {
        "a": _pkg("a", "amd64", dependencies = [_dep("b")]),
        "b": _pkg("b", "amd64", dependencies = [_dep("a")]),
    }

    result = testing._closure_for_arch(by_name, ["a"])

    names = [p["name"] for p in result]
    asserts.equals(env, names, ["a", "b"])

    return unittest.end(env)

closure_handles_cycle_test = unittest.make(_closure_handles_cycle_test_impl)

def _closure_skips_unknown_names_test_impl(ctx):
    """Closure tolerates requested-but-absent names (defensive)."""
    env = unittest.begin(ctx)

    by_name = {
        "known": _pkg("known", "amd64"),
    }

    result = testing._closure_for_arch(by_name, ["known", "missing"])

    names = [p["name"] for p in result]
    asserts.equals(env, names, ["known"])

    return unittest.end(env)

closure_skips_unknown_names_test = unittest.make(
    _closure_skips_unknown_names_test_impl,
)

def _transitive_closure_by_arch_per_arch_test_impl(ctx):
    """End-to-end: per-arch closure runs independently on each arch's graph."""
    env = unittest.begin(ctx)

    packages = [
        _pkg("a", "amd64", dependencies = [_dep("b")]),
        _pkg("b", "amd64"),
        # arm64 graph is smaller: only `a` exists, dep "b" missing on arm64.
        _pkg("a", "arm64"),
    ]

    closures = closure.transitive_closure_by_arch(packages, ["a"])

    amd64_names = [p["name"] for p in closures["amd64"]]
    arm64_names = [p["name"] for p in closures["arm64"]]

    asserts.equals(env, amd64_names, ["a", "b"])
    asserts.equals(env, arm64_names, ["a"])

    return unittest.end(env)

transitive_closure_by_arch_per_arch_test = unittest.make(
    _transitive_closure_by_arch_per_arch_test_impl,
)

TEST_SUITE_NAME = "closure"

TEST_SUITE_TESTS = dict(
    closure_handles_cycle = closure_handles_cycle_test,
    closure_handles_diamond_dep = closure_handles_diamond_dep_test,
    closure_skips_unknown_names = closure_skips_unknown_names_test,
    closure_walks_transitive_deps = closure_walks_transitive_deps_test,
    index_by_arch_groups_packages = index_by_arch_groups_packages_test,
    transitive_closure_by_arch_per_arch = transitive_closure_by_arch_per_arch_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
