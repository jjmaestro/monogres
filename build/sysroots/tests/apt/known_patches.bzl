"""
Unit tests for `//sysroots/apt/private:known_patches.bzl`.

The registry is empty by default (see the module docstring); the rctx-using
`apply` wrapper is exercised end-to-end by the examples workspace under
`examples/`. This file pins the empty-registry shape so adding an entry without
thinking about the read-only `@hub` constraint trips a test.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//apt/private:known_patches.bzl", _known_patches = "known_patches")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _known_patches_registry_empty_test_impl(ctx):
    """The default registry is empty: patchers added in downstream forks only."""
    env = unittest.begin(ctx)
    asserts.equals(env, {}, _known_patches.KNOWN_PATCHES)
    return unittest.end(env)

known_patches_registry_empty_test = unittest.make(
    _known_patches_registry_empty_test_impl,
)

TEST_SUITE_NAME = "known_patches"

TEST_SUITE_TESTS = dict(
    known_patches_registry_empty = known_patches_registry_empty_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
