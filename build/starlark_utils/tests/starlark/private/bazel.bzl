"""Tests for Bazel convenience wrappers (glob, select, load)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//starlark:starlark.bzl", Star = "starlark")

def _glob_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'glob(["**/*.bzl"])'
    actual = Star.gen(Star.glob(["**/*.bzl"]))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

glob_test = unittest.make(_glob_test_impl)

def _glob_exclude_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = """\
glob(
    [
        "**/*.bzl",
    ],
    exclude = [
        "test/**",
    ],
)"""
    actual = Star.igen(Star.glob(["**/*.bzl"], exclude = ["test/**"]))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

glob_exclude_test = unittest.make(_glob_exclude_test_impl)

def _select_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'select({"//conditions:default": []})'
    actual = Star.gen(Star.select({"//conditions:default": []}))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

select_test = unittest.make(_select_test_impl)

def _select_indent_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = """\
select({
    "//conditions:default": [],
})"""
    actual = Star.igen(Star.select({"//conditions:default": []}))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

select_indent_test = unittest.make(_select_indent_test_impl)

def _load_args_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'load("//foo:bar.bzl", "FOO", "foobar")'
    actual = Star.gen(Star.load_("//foo:bar.bzl", "FOO", "foobar"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

load_args_test = unittest.make(_load_args_test_impl)

def _load_args_and_kwargs_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'load("//foo:bar.bzl", "FOO", _foobar = "foobar")'
    actual = Star.gen(Star.load_("//foo:bar.bzl", "FOO", _foobar = "foobar"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

load_args_and_kwargs_test = unittest.make(_load_args_and_kwargs_test_impl)

TEST_SUITE_TESTS = dict(
    glob = glob_test,
    glob_exclude = glob_exclude_test,
    select = select_test,
    select_indent = select_indent_test,
    load_args = load_args_test,
    load_args_and_kwargs = load_args_and_kwargs_test,
)
