"""Tests for assignments and load helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//starlark:starlark.bzl", Star = "starlark")

def _assignments_test_impl(ctx):
    env = unittest.begin(ctx)

    def test(assignments):
        # inline (default)
        expected = 'FOO = 42, BAR = "foobar"'
        actual = Star.assignments(assignments)

        asserts.equals(env, expected, actual)

        # multi-line
        expected = """
FOO = 42
BAR = "foobar"
        """.strip()
        actual = Star.assignments(assignments, inline = False)

        asserts.equals(env, expected, actual)

    # test all types
    params = [
        dict(FOO = 42, BAR = "foobar"),
        [("FOO", 42), ["BAR", "foobar"]],
        (["FOO", 42], ("BAR", "foobar")),
        (("FOO", 42), ("BAR", "foobar")),
    ]

    for assignments in params:
        test(assignments)

    return unittest.end(env)

assignments_test = unittest.make(_assignments_test_impl)

def _assignments_indent_test_impl(ctx):
    env = unittest.begin(ctx)

    assignments = dict(FOO = 42, BAR = "foobar")

    # indent_count=1 with default indent_size=4: NOTE: the leading whitespace
    # before FOO and BAR is the indent (4 spaces)
    expected = """\
    FOO = 42
    BAR = "foobar"\
"""
    actual = Star.assignments(assignments, inline = False, indent_count = 1)

    asserts.equals(env, expected, actual)

    # indent_count=2 with indent_size=3:
    # NOTE: the leading whitespace is 6 spaces (2 * 3)
    expected = """\
      FOO = 42
      BAR = "foobar"\
"""
    actual = Star.assignments(
        assignments,
        inline = False,
        indent_count = 2,
        indent_size = 3,
    )

    asserts.equals(env, expected, actual)

    # indent_count=0 (default) should behave like before
    expected = """
FOO = 42
BAR = "foobar"
    """.strip()
    actual = Star.assignments(assignments, inline = False, indent_count = 0)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

assignments_indent_test = unittest.make(_assignments_indent_test_impl)

def _load_args_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'load("//foo:bar.bzl", "FOO", "foobar")'
    actual = Star.load_("//foo:bar.bzl", "FOO", "foobar")

    asserts.equals(env, expected, actual)

    return unittest.end(env)

load_args_test = unittest.make(_load_args_test_impl)

def _load_args_and_kwargs_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'load("//foo:bar.bzl", "FOO", _foobar = "foobar")'
    actual = Star.load_("//foo:bar.bzl", "FOO", _foobar = "foobar")

    asserts.equals(env, expected, actual)

    return unittest.end(env)

load_args_and_kwargs_test = unittest.make(_load_args_and_kwargs_test_impl)

TEST_SUITE_TESTS = dict(
    assignments = assignments_test,
    assignments_indent = assignments_indent_test,
    load_args = load_args_test,
    load_args_and_kwargs = load_args_and_kwargs_test,
)
