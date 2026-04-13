"""
Unit tests for monoext/private/ext/compat.bzl.

Tests `is_compatible(name, ext_version, base_version, metadata, debug)`, the
wrapper around `base/compat.is_compatible_with` that reads an extension's
`compatible_with` map from repo.json metadata.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/ext:compat.bzl", "is_compatible")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _no_metadata_defaults_to_wildcard_test_impl(ctx):
    """Missing metadata → `*` → every PG version is compatible."""
    env = unittest.begin(ctx)

    asserts.true(env, is_compatible("citus", "13.2.0", "18.1"))
    asserts.true(env, is_compatible("citus", "13.2.0", "17.0"))
    asserts.true(env, is_compatible("noset", "0.3.0", "13.0"))

    return unittest.end(env)

no_metadata_defaults_to_wildcard_test = unittest.make(
    _no_metadata_defaults_to_wildcard_test_impl,
)

def _empty_compatible_with_defaults_to_wildcard_test_impl(ctx):
    """Metadata without `compatible_with` → `*` → every PG version is compatible."""
    env = unittest.begin(ctx)

    asserts.true(
        env,
        is_compatible("citus", "13.2.0", "18.1", metadata = {}),
    )
    asserts.true(
        env,
        is_compatible(
            "citus",
            "13.2.0",
            "18.1",
            metadata = {"compatible_with": {}},
        ),
    )

    return unittest.end(env)

empty_compatible_with_defaults_to_wildcard_test = unittest.make(
    _empty_compatible_with_defaults_to_wildcard_test_impl,
)

def _explicit_compatible_with_range_test_impl(ctx):
    """An explicit `compatible_with` range filters PG versions."""
    env = unittest.begin(ctx)

    metadata = {
        "compatible_with": {
            "13.2.0": ">=16, <18",
        },
    }

    asserts.true(env, is_compatible("citus", "13.2.0", "16.0", metadata))
    asserts.true(env, is_compatible("citus", "13.2.0", "17.5", metadata))
    asserts.false(env, is_compatible("citus", "13.2.0", "15.9", metadata))
    asserts.false(env, is_compatible("citus", "13.2.0", "18.0", metadata))

    return unittest.end(env)

explicit_compatible_with_range_test = unittest.make(
    _explicit_compatible_with_range_test_impl,
)

def _other_ext_versions_unaffected_test_impl(ctx):
    """`compatible_with` is per-extension-version."""
    env = unittest.begin(ctx)

    metadata = {
        "compatible_with": {
            "13.2.0": ">=16, <18",
            # ext_version "99.0.0" is not listed → defaults to `*`
        },
    }

    asserts.false(env, is_compatible("citus", "13.2.0", "15.9", metadata))
    asserts.true(env, is_compatible("citus", "99.0.0", "15.9", metadata))

    return unittest.end(env)

other_ext_versions_unaffected_test = unittest.make(
    _other_ext_versions_unaffected_test_impl,
)

TEST_SUITE_NAME = "compat"

TEST_SUITE_TESTS = dict(
    empty_compatible_with_defaults_to_wildcard = empty_compatible_with_defaults_to_wildcard_test,
    explicit_compatible_with_range = explicit_compatible_with_range_test,
    no_metadata_defaults_to_wildcard = no_metadata_defaults_to_wildcard_test,
    other_ext_versions_unaffected = other_ext_versions_unaffected_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
