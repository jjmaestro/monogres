"""
Unit tests for monoext/private/ext/compat.bzl.

Tests `is_compatible(name, ext_version, flavor, base_version, metadata, debug)`,
the wrapper around `base/compat.is_compatible_with` that reads an extension's
`compatible_with` map from repo.json metadata.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/ext:compat.bzl", "is_compatible")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _no_metadata_defaults_to_wildcard_test_impl(ctx):
    """Missing metadata → `*` → every version is compatible for any flavor."""
    env = unittest.begin(ctx)

    asserts.true(env, is_compatible("citus", "13.2.0", "postgres", "18.1"))
    asserts.true(env, is_compatible("citus", "13.2.0", "postgres", "17.0"))
    asserts.true(env, is_compatible("noset", "0.3.0", "postgres", "13.0"))
    asserts.true(env, is_compatible("noset", "0.3.0", "ivorysql", "5.0"))

    return unittest.end(env)

no_metadata_defaults_to_wildcard_test = unittest.make(
    _no_metadata_defaults_to_wildcard_test_impl,
)

def _empty_compatible_with_defaults_to_wildcard_test_impl(ctx):
    """Metadata without `compatible_with` → `*` → every version is compatible."""
    env = unittest.begin(ctx)

    asserts.true(
        env,
        is_compatible("citus", "13.2.0", "postgres", "18.1", metadata = {}),
    )
    asserts.true(
        env,
        is_compatible(
            "citus",
            "13.2.0",
            "postgres",
            "18.1",
            metadata = {"other_key": "value"},
        ),
    )

    return unittest.end(env)

empty_compatible_with_defaults_to_wildcard_test = unittest.make(
    _empty_compatible_with_defaults_to_wildcard_test_impl,
)

def _explicit_compatible_with_range_test_impl(ctx):
    """An explicit `compatible_with` range filters base versions."""
    env = unittest.begin(ctx)

    metadata = {
        "compatible_with": {
            "postgres": {
                "13.2.0": ">=16, <18",
            },
        },
    }

    asserts.true(
        env,
        is_compatible("citus", "13.2.0", "postgres", "16.0", metadata),
    )
    asserts.true(
        env,
        is_compatible("citus", "13.2.0", "postgres", "17.5", metadata),
    )
    asserts.false(
        env,
        is_compatible("citus", "13.2.0", "postgres", "15.9", metadata),
    )
    asserts.false(
        env,
        is_compatible("citus", "13.2.0", "postgres", "18.0", metadata),
    )

    return unittest.end(env)

explicit_compatible_with_range_test = unittest.make(
    _explicit_compatible_with_range_test_impl,
)

def _missing_flavor_key_returns_false_test_impl(ctx):
    """compatible_with present but missing flavor key → not compatible (explicit opt-in)."""
    env = unittest.begin(ctx)

    metadata = {
        "compatible_with": {
            "postgres": {
                "13.2.0": "<=17",
            },
        },
    }

    asserts.true(
        env,
        is_compatible("citus", "13.2.0", "postgres", "17.0", metadata),
    )
    asserts.false(
        env,
        is_compatible("citus", "13.2.0", "ivorysql", "5.0", metadata),
    )

    return unittest.end(env)

missing_flavor_key_returns_false_test = unittest.make(
    _missing_flavor_key_returns_false_test_impl,
)

def _citus_compat_postgres_only_test_impl(ctx):
    """citus <=17 matches postgres 17.5 but not 18.0, and is absent for ivorysql."""
    env = unittest.begin(ctx)

    metadata = {
        "compatible_with": {
            "postgres": {
                "13.2.0": "<=17",
            },
        },
    }

    asserts.true(
        env,
        is_compatible("citus", "13.2.0", "postgres", "17.5", metadata),
    )
    asserts.false(
        env,
        is_compatible("citus", "13.2.0", "postgres", "18.0", metadata),
    )
    asserts.false(
        env,
        is_compatible("citus", "13.2.0", "ivorysql", "3.0", metadata),
    )

    return unittest.end(env)

citus_compat_postgres_only_test = unittest.make(
    _citus_compat_postgres_only_test_impl,
)

def _two_flavor_metadata_independent_test_impl(ctx):
    """Two-flavor metadata: each flavor uses its own range independently."""
    env = unittest.begin(ctx)

    metadata = {
        "compatible_with": {
            "ivorysql": {
                "0.3.0": ">=5.0",
            },
            "postgres": {
                "0.3.0": ">=14",
            },
        },
    }

    asserts.true(
        env,
        is_compatible("noset", "0.3.0", "postgres", "14.0", metadata),
    )
    asserts.true(
        env,
        is_compatible("noset", "0.3.0", "postgres", "18.1", metadata),
    )
    asserts.false(
        env,
        is_compatible("noset", "0.3.0", "postgres", "13.0", metadata),
    )

    asserts.true(
        env,
        is_compatible("noset", "0.3.0", "ivorysql", "5.0", metadata),
    )
    asserts.false(
        env,
        is_compatible("noset", "0.3.0", "ivorysql", "4.0", metadata),
    )
    asserts.false(
        env,
        is_compatible("noset", "0.3.0", "ivorysql", "3.0", metadata),
    )

    return unittest.end(env)

two_flavor_metadata_independent_test = unittest.make(
    _two_flavor_metadata_independent_test_impl,
)

def _missing_ext_version_in_flavor_returns_false_test_impl(ctx):
    """Flavor key present but ext_v not declared → not compatible."""
    env = unittest.begin(ctx)

    metadata = {
        "compatible_with": {
            "postgres": {
                "0.3.0": ">=14",
            },
        },
    }

    asserts.true(
        env,
        is_compatible("noset", "0.3.0", "postgres", "18.1", metadata),
    )
    asserts.false(
        env,
        is_compatible("noset", "0.2.0", "postgres", "18.1", metadata),
    )

    return unittest.end(env)

missing_ext_version_in_flavor_returns_false_test = unittest.make(
    _missing_ext_version_in_flavor_returns_false_test_impl,
)

TEST_SUITE_NAME = "compat"

TEST_SUITE_TESTS = dict(
    citus_compat_postgres_only = citus_compat_postgres_only_test,
    empty_compatible_with_defaults_to_wildcard = empty_compatible_with_defaults_to_wildcard_test,
    explicit_compatible_with_range = explicit_compatible_with_range_test,
    missing_ext_version_in_flavor_returns_false = missing_ext_version_in_flavor_returns_false_test,
    missing_flavor_key_returns_false = missing_flavor_key_returns_false_test,
    no_metadata_defaults_to_wildcard = no_metadata_defaults_to_wildcard_test,
    two_flavor_metadata_independent = two_flavor_metadata_independent_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
