"""
Unit tests for monoext/private/pkgs/collect.bzl.

Tests collect_package_groups() iterating extensions, resolving version-specific
deps, and building globally-deduplicated package groups.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/pkgs:collect.bzl", "collect_package_groups")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _single_extension_wildcard_deps_test_impl(ctx):
    """Single extension with wildcard deps"""
    env = unittest.begin(ctx)

    extensions = {
        "citus": {
            "ext_versions": ["13.2.0"],
            "metadata": {
                "deps": {
                    "buildtime": {
                        "debian": {"12": {"*": ["pkg-a", "pkg-b"]}},
                    },
                    "runtime": {
                        "debian": {"12": {"*": ["pkg-c"]}},
                    },
                },
            },
        },
    }

    groups, dep_groups = collect_package_groups(extensions, "12")

    # one buildtime group, one runtime group
    asserts.equals(env, 2, len(groups))

    # both kinds present, entries point to group keys
    bt_key = dep_groups["buildtime"][("citus", "13.2.0")]
    rt_key = dep_groups["runtime"][("citus", "13.2.0")]

    asserts.true(env, bt_key in groups)
    asserts.true(env, rt_key in groups)
    asserts.true(env, bt_key != rt_key)

    return unittest.end(env)

single_extension_wildcard_deps_test = unittest.make(
    _single_extension_wildcard_deps_test_impl,
)

def _two_extensions_shared_deps_test_impl(ctx):
    """Two extensions with shared deps → same group key"""
    env = unittest.begin(ctx)

    shared_deps = {"*": ["libssl-dev"]}

    extensions = {
        "citus": {
            "ext_versions": ["13.2.0"],
            "metadata": {
                "deps": {"buildtime": {"debian": {"12": shared_deps}}},
            },
        },
        "sslutils": {
            "ext_versions": ["1.4"],
            "metadata": {
                "deps": {"buildtime": {"debian": {"12": shared_deps}}},
            },
        },
    }

    groups, dep_groups = collect_package_groups(extensions, "12")

    bt_citus = dep_groups["buildtime"][("citus", "13.2.0")]
    bt_sslutils = dep_groups["buildtime"][("sslutils", "1.4")]

    # same packages → same group key (content-addressed dedup)
    asserts.equals(env, bt_citus, bt_sslutils)

    # only one buildtime group in the map
    asserts.equals(env, 1, len(groups))

    return unittest.end(env)

two_extensions_shared_deps_test = unittest.make(
    _two_extensions_shared_deps_test_impl,
)

def _two_extensions_different_deps_test_impl(ctx):
    """Two extensions with different deps → different group keys"""
    env = unittest.begin(ctx)

    extensions = {
        "ext_a": {
            "ext_versions": ["1.0.0"],
            "metadata": {
                "deps": {"buildtime": {"debian": {"12": {"*": ["pkg-a"]}}}},
            },
        },
        "ext_b": {
            "ext_versions": ["1.0.0"],
            "metadata": {
                "deps": {"buildtime": {"debian": {"12": {"*": ["pkg-b"]}}}},
            },
        },
    }

    groups, dep_groups = collect_package_groups(extensions, "12")

    bt_a = dep_groups["buildtime"][("ext_a", "1.0.0")]
    bt_b = dep_groups["buildtime"][("ext_b", "1.0.0")]

    asserts.true(env, bt_a != bt_b)
    asserts.equals(env, 2, len(groups))

    return unittest.end(env)

two_extensions_different_deps_test = unittest.make(
    _two_extensions_different_deps_test_impl,
)

def _version_specific_deps_test_impl(ctx):
    """Version-specific deps → different groups for different versions"""
    env = unittest.begin(ctx)

    extensions = {
        "myext": {
            "ext_versions": ["1.0.0", "2.0.0"],
            "metadata": {
                "deps": {
                    "buildtime": {
                        "debian": {
                            "12": {
                                ">=1.0.0, <2.0.0": ["pkg-a"],
                                ">=2.0.0": ["pkg-a", "pkg-b"],
                            },
                        },
                    },
                },
            },
        },
    }

    groups, dep_groups = collect_package_groups(extensions, "12")

    bt_v1 = dep_groups["buildtime"][("myext", "1.0.0")]
    bt_v2 = dep_groups["buildtime"][("myext", "2.0.0")]

    # different versions get different group keys
    asserts.true(env, bt_v1 != bt_v2)

    # v1 has 1 package, v2 has 2
    asserts.equals(env, ["pkg-a"], groups[bt_v1])
    asserts.equals(env, ["pkg-a", "pkg-b"], groups[bt_v2])

    return unittest.end(env)

version_specific_deps_test = unittest.make(
    _version_specific_deps_test_impl,
)

def _extension_with_no_deps_test_impl(ctx):
    """Extension with no deps → no entries"""
    env = unittest.begin(ctx)

    extensions = {
        "noset": {
            "ext_versions": ["0.3.0"],
            "metadata": {},
        },
    }

    groups, dep_groups = collect_package_groups(extensions, "12")

    asserts.equals(env, {}, groups)
    asserts.equals(env, {}, dep_groups)

    return unittest.end(env)

extension_with_no_deps_test = unittest.make(
    _extension_with_no_deps_test_impl,
)

def _dedup_identical_package_sets_test_impl(ctx):
    """Dedup: identical package sets from different extensions → same key"""
    env = unittest.begin(ctx)

    extensions = {
        "ext_a": {
            "ext_versions": ["1.0.0"],
            "metadata": {
                "deps": {
                    "buildtime": {
                        "debian": {"12": {"*": ["pkg-a", "pkg-b"]}},
                    },
                },
            },
        },
        "ext_b": {
            "ext_versions": ["2.0.0"],
            "metadata": {
                "deps": {
                    "buildtime": {
                        # same packages, different order in source
                        "debian": {"12": {"*": ["pkg-b", "pkg-a"]}},
                    },
                },
            },
        },
    }

    groups, dep_groups = collect_package_groups(extensions, "12")

    bt_a = dep_groups["buildtime"][("ext_a", "1.0.0")]
    bt_b = dep_groups["buildtime"][("ext_b", "2.0.0")]

    # same sorted packages → same content-addressed key
    asserts.equals(env, bt_a, bt_b)
    asserts.equals(env, 1, len(groups))

    return unittest.end(env)

dedup_identical_package_sets_test = unittest.make(
    _dedup_identical_package_sets_test_impl,
)

def _buildtime_and_runtime_separate_test_impl(ctx):
    """Buildtime and runtime are separate groups"""
    env = unittest.begin(ctx)

    extensions = {
        "myext": {
            "ext_versions": ["1.0.0"],
            "metadata": {
                "deps": {
                    "buildtime": {"debian": {"12": {"*": ["pkg-a"]}}},
                    "runtime": {"debian": {"12": {"*": ["pkg-b"]}}},
                },
            },
        },
    }

    groups, dep_groups = collect_package_groups(extensions, "12")

    bt = dep_groups["buildtime"][("myext", "1.0.0")]
    rt = dep_groups["runtime"][("myext", "1.0.0")]

    asserts.true(env, bt != rt)
    asserts.equals(env, 2, len(groups))

    return unittest.end(env)

buildtime_and_runtime_separate_test = unittest.make(
    _buildtime_and_runtime_separate_test_impl,
)

TEST_SUITE_NAME = "collect"

TEST_SUITE_TESTS = dict(
    single_extension_wildcard_deps = single_extension_wildcard_deps_test,
    two_extensions_shared_deps = two_extensions_shared_deps_test,
    two_extensions_different_deps = two_extensions_different_deps_test,
    version_specific_deps = version_specific_deps_test,
    extension_with_no_deps = extension_with_no_deps_test,
    dedup_identical_package_sets = dedup_identical_package_sets_test,
    buildtime_and_runtime_separate = buildtime_and_runtime_separate_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
