"""
Unit tests for `//sysroots/common:extra_files.bzl`.

The rctx-using `apply` wrapper is exercised end-to-end by the examples workspace
under `examples/`; this file covers `resolve_target_path` placeholder
substitution.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//common:extra_files.bzl", _extra_files = "extra_files")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _resolve_no_placeholder_test_impl(ctx):
    """A path without {arch} is appended verbatim."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "/sys/usr/lib/llvm-14/bin/clang",
        _extra_files.resolve_target_path(
            "/sys",
            "amd64",
            "usr/lib/llvm-14/bin/clang",
        ),
    )
    return unittest.end(env)

resolve_no_placeholder_test = unittest.make(_resolve_no_placeholder_test_impl)

def _resolve_with_placeholder_test_impl(ctx):
    """A {arch} placeholder is substituted with the per-arch value."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "/sys/usr/lib/amd64-linux-gnu/foo",
        _extra_files.resolve_target_path(
            "/sys",
            "amd64",
            "usr/lib/{arch}-linux-gnu/foo",
        ),
    )
    asserts.equals(
        env,
        "/sys/usr/lib/arm64-linux-gnu/foo",
        _extra_files.resolve_target_path(
            "/sys",
            "arm64",
            "usr/lib/{arch}-linux-gnu/foo",
        ),
    )
    return unittest.end(env)

resolve_with_placeholder_test = unittest.make(
    _resolve_with_placeholder_test_impl,
)

def _resolve_multiple_placeholders_test_impl(ctx):
    """All occurrences of {arch} are substituted, not just the first."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "/sys/arm64/lib/arm64-foo",
        _extra_files.resolve_target_path(
            "/sys",
            "arm64",
            "{arch}/lib/{arch}-foo",
        ),
    )
    return unittest.end(env)

resolve_multiple_placeholders_test = unittest.make(
    _resolve_multiple_placeholders_test_impl,
)

TEST_SUITE_NAME = "extra_files"

TEST_SUITE_TESTS = dict(
    resolve_multiple_placeholders = resolve_multiple_placeholders_test,
    resolve_no_placeholder = resolve_no_placeholder_test,
    resolve_with_placeholder = resolve_with_placeholder_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
