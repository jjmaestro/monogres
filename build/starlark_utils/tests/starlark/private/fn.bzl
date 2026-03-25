"""Tests for fn() function call builder."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//starlark:starlark.bzl", Star = "starlark")

def _fn_empty_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "cfg.new()"
    actual = Star.gen(Star.fn("cfg.new"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_empty_test = unittest.make(_fn_empty_test_impl)

def _fn_inline_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'cfg.new(name = "citus", flag = True)'
    actual = Star.gen(Star.fn("cfg.new", name = "citus", flag = True))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_inline_test = unittest.make(_fn_inline_test_impl)

def _fn_indent_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = """\
cfg.new(
    name = "citus",
    flag = True,
)"""
    actual = Star.igen(Star.fn("cfg.new", name = "citus", flag = True))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_indent_test = unittest.make(_fn_indent_test_impl)

def _fn_kwargs_unquoted_test_impl(ctx):
    """Fn with kwargs and quote_strings=False for bare variable references"""
    env = unittest.begin(ctx)

    expected = """\
cfg.new(
    name = "citus",
    versions = VERSIONS_0,
)"""
    actual = Star.igen(
        Star.fn("cfg.new", name = '"citus"', versions = "VERSIONS_0"),
        quote_strings = False,
    )

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_kwargs_unquoted_test = unittest.make(_fn_kwargs_unquoted_test_impl)

def _fn_positional_test_impl(ctx):
    """Fn with positional args inline"""
    env = unittest.begin(ctx)

    expected = 'f("a", 1)'
    actual = Star.gen(Star.fn("f", "a", 1))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_positional_test = unittest.make(_fn_positional_test_impl)

def _fn_positional_indent_test_impl(ctx):
    """Fn with positional args indented"""
    env = unittest.begin(ctx)

    expected = """\
f(
    "a",
    1,
)"""
    actual = Star.igen(Star.fn("f", "a", 1))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_positional_indent_test = unittest.make(_fn_positional_indent_test_impl)

def _fn_mixed_test_impl(ctx):
    """Fn with positional and keyword args inline"""
    env = unittest.begin(ctx)

    expected = 'f("a", name = "b")'
    actual = Star.gen(Star.fn("f", "a", name = "b"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_mixed_test = unittest.make(_fn_mixed_test_impl)

def _fn_mixed_indent_test_impl(ctx):
    """Fn with positional and keyword args indented"""
    env = unittest.begin(ctx)

    expected = """\
f(
    "a",
    name = "b",
)"""
    actual = Star.igen(Star.fn("f", "a", name = "b"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_mixed_indent_test = unittest.make(_fn_mixed_indent_test_impl)

def _fn_in_list_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = """\
[
    cfg.new(
        name = "citus",
    ),
]"""
    actual = Star.igen([Star.fn("cfg.new", name = "citus")])

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_in_list_test = unittest.make(_fn_in_list_test_impl)

def _fn_in_dict_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = """\
{
    "citus": cfg.new(
        name = "citus",
    ),
}"""
    actual = Star.igen({"citus": Star.fn("cfg.new", name = "citus")})

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_in_dict_test = unittest.make(_fn_in_dict_test_impl)

def _fn_nested_test_impl(ctx):
    """Fn with a nested struct and list arg"""
    env = unittest.begin(ctx)

    expected = """\
outer(
    inner = cfg.new(
        name = "citus",
    ),
    items = [
        1,
        2,
    ],
)"""
    actual = Star.igen(Star.fn(
        "outer",
        inner = Star.fn("cfg.new", name = "citus"),
        items = [1, 2],
    ))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_nested_test = unittest.make(_fn_nested_test_impl)

def _fn_with_struct_test_impl(ctx):
    """Fn containing a struct value"""
    env = unittest.begin(ctx)

    expected = """\
cfg.new(
    target = struct(
        name = "pg16",
    ),
)"""
    actual = Star.igen(Star.fn(
        "cfg.new",
        target = struct(name = "pg16"),
    ))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_with_struct_test = unittest.make(_fn_with_struct_test_impl)

## --- fn merged brackets ----------------------------------

def _fn_merged_list_test_impl(ctx):
    """Fn with single list arg merges brackets"""
    env = unittest.begin(ctx)

    expected = """f([
    1,
    2,
])"""
    actual = Star.igen(Star.fn("f", [1, 2]))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_merged_list_test = unittest.make(_fn_merged_list_test_impl)

def _fn_merged_empty_test_impl(ctx):
    """Fn with single empty list arg"""
    env = unittest.begin(ctx)

    expected = "f([])"
    actual = Star.gen(Star.fn("f", []))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_merged_empty_test = unittest.make(_fn_merged_empty_test_impl)

def _fn_merged_inline_test_impl(ctx):
    """Fn with single list arg inline"""
    env = unittest.begin(ctx)

    expected = "f([1, 2])"
    actual = Star.gen(Star.fn("f", [1, 2]))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_merged_inline_test = unittest.make(_fn_merged_inline_test_impl)

def _fn_merged_dict_test_impl(ctx):
    """Fn with single dict arg merges brackets"""
    env = unittest.begin(ctx)

    expected = """\
f({
    "a": 1,
})"""
    actual = Star.igen(Star.fn("f", {"a": 1}))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_merged_dict_test = unittest.make(_fn_merged_dict_test_impl)

def _fn_no_merge_kwargs_test_impl(ctx):
    """Single container arg with kwargs does not merge"""
    env = unittest.begin(ctx)

    expected = """f(
    [
        1,
    ],
    x = 2,
)"""
    actual = Star.igen(Star.fn("f", [1], x = 2))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_no_merge_kwargs_test = unittest.make(_fn_no_merge_kwargs_test_impl)

def _fn_no_merge_multi_test_impl(ctx):
    """Multiple positional args do not merge"""
    env = unittest.begin(ctx)

    expected = """f(
    [
        1,
    ],
    [
        2,
    ],
)"""
    actual = Star.igen(Star.fn("f", [1], [2]))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

fn_no_merge_multi_test = unittest.make(_fn_no_merge_multi_test_impl)

## --- depset via fn -----------------------------------

def _depset_kwargs_test_impl(ctx):
    """depset() with positional direct list and transitive kwarg, inline"""
    env = unittest.begin(ctx)

    expected = 'depset(["d", "e"], transitive = [s])'
    actual = Star.gen(
        Star.fn("depset", ['"d"', '"e"'], transitive = ["s"]),
        quote_strings = False,
    )

    asserts.equals(env, expected, actual)

    return unittest.end(env)

depset_kwargs_test = unittest.make(_depset_kwargs_test_impl)

def _depset_kwargs_indent_test_impl(ctx):
    """depset() with kwargs, indented"""
    env = unittest.begin(ctx)

    expected = """\
depset(
    [
        "d",
        "e",
    ],
    transitive = [
        s,
    ],
)"""
    actual = Star.igen(
        Star.fn("depset", ['"d"', '"e"'], transitive = ["s"]),
        quote_strings = False,
    )

    asserts.equals(env, expected, actual)

    return unittest.end(env)

depset_kwargs_indent_test = unittest.make(_depset_kwargs_indent_test_impl)

TEST_SUITE_TESTS = dict(
    fn_empty = fn_empty_test,
    fn_inline = fn_inline_test,
    fn_indent = fn_indent_test,
    fn_kwargs_unquoted = fn_kwargs_unquoted_test,
    fn_positional = fn_positional_test,
    fn_positional_indent = fn_positional_indent_test,
    fn_mixed = fn_mixed_test,
    fn_mixed_indent = fn_mixed_indent_test,
    fn_in_list = fn_in_list_test,
    fn_in_dict = fn_in_dict_test,
    fn_nested = fn_nested_test,
    fn_with_struct = fn_with_struct_test,
    # fn merged brackets
    fn_merged_list = fn_merged_list_test,
    fn_merged_empty = fn_merged_empty_test,
    fn_merged_inline = fn_merged_inline_test,
    fn_merged_dict = fn_merged_dict_test,
    fn_no_merge_kwargs = fn_no_merge_kwargs_test,
    fn_no_merge_multi = fn_no_merge_multi_test,
    # depset via fn
    depset_kwargs = depset_kwargs_test,
    depset_kwargs_indent = depset_kwargs_indent_test,
)
