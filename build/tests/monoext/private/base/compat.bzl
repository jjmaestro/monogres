"""
Unit tests for monoext/private/base/compat.bzl.

Tests `is_compatible_with(version, constraint_spec, debug_prefix)` across the
PGVER-scheme constraints used in PG build options and extension compatibility
metadata.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/base:compat.bzl", "is_compatible_with")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _wildcard_matches_everything_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.true(env, is_compatible_with("18.1", "*"))
    asserts.true(env, is_compatible_with("17.0", "*"))
    asserts.true(env, is_compatible_with("13.0", "*"))

    return unittest.end(env)

wildcard_matches_everything_test = unittest.make(
    _wildcard_matches_everything_test_impl,
)

def _range_inclusive_lower_exclusive_upper_test_impl(ctx):
    """`>=16, <18` matches 16..17 but not 15 or 18."""
    env = unittest.begin(ctx)

    asserts.true(env, is_compatible_with("16.0", ">=16, <18"))
    asserts.true(env, is_compatible_with("17.5", ">=16, <18"))
    asserts.false(env, is_compatible_with("15.9", ">=16, <18"))
    asserts.false(env, is_compatible_with("18.0", ">=16, <18"))

    return unittest.end(env)

range_inclusive_lower_exclusive_upper_test = unittest.make(
    _range_inclusive_lower_exclusive_upper_test_impl,
)

def _exact_lower_bound_test_impl(ctx):
    """`>=X` matches X and everything above."""
    env = unittest.begin(ctx)

    asserts.true(env, is_compatible_with("16.0", ">=16"))
    asserts.true(env, is_compatible_with("17.0", ">=16"))
    asserts.true(env, is_compatible_with("18.1", ">=16"))
    asserts.false(env, is_compatible_with("15.0", ">=16"))

    return unittest.end(env)

exact_lower_bound_test = unittest.make(_exact_lower_bound_test_impl)

def _upper_bound_exclusive_test_impl(ctx):
    """`<X` matches everything strictly less than X."""
    env = unittest.begin(ctx)

    asserts.true(env, is_compatible_with("15.9", "<16"))
    asserts.false(env, is_compatible_with("16.0", "<16"))
    asserts.false(env, is_compatible_with("17.0", "<16"))

    return unittest.end(env)

upper_bound_exclusive_test = unittest.make(_upper_bound_exclusive_test_impl)

TEST_SUITE_NAME = "compat"

TEST_SUITE_TESTS = dict(
    exact_lower_bound = exact_lower_bound_test,
    range_inclusive_lower_exclusive_upper = range_inclusive_lower_exclusive_upper_test,
    upper_bound_exclusive = upper_bound_exclusive_test,
    wildcard_matches_everything = wildcard_matches_everything_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
