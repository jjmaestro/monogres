"""Tests for the core gen/igen/auto renderer."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//starlark:starlark.bzl", Star = "starlark")

_DICT = dict(
    key = [1, 2, {"a": 1}],
    flag = True,
    name = "example",
    a = "{foo}",
)
_DICT[42] = None

def _escape_test_impl(ctx):
    env = unittest.begin(ctx)

    parameters = {
        "": "",
        "\n": "\\n",
        '"foo"': '"foo"',
        "\\e": "\\\\e",
        "foo": "foo",
    }

    for s, expected in parameters.items():
        actual = Star.__test__._escape(s)
        asserts.equals(env, expected, actual)

    return unittest.end(env)

escape_test = unittest.make(_escape_test_impl)

def _gen_backslash_test_impl(ctx):
    """gen() must emit a single backslash as a properly escaped string."""
    env = unittest.begin(ctx)

    asserts.equals(env, '"a\\\\b"', Star.gen("a\\b"))
    asserts.equals(env, '"a\\\\b"', Star.gen("a\\b", quote_strings = True))
    asserts.equals(env, "a\\\\b", Star.gen("a\\b", quote_strings = False))

    return unittest.end(env)

gen_backslash_test = unittest.make(_gen_backslash_test_impl)

def _gen_newline_test_impl(ctx):
    """gen() must emit a newline as the escape sequence \\n."""
    env = unittest.begin(ctx)

    asserts.equals(env, '"a\\nb"', Star.gen("a\nb"))
    asserts.equals(env, '"a\\nb"', Star.gen("a\nb", quote_strings = True))
    asserts.equals(env, "a\\nb", Star.gen("a\nb", quote_strings = False))

    return unittest.end(env)

gen_newline_test = unittest.make(_gen_newline_test_impl)

def _gen_tab_test_impl(ctx):
    """gen() must emit a tab as the escape sequence \\t."""
    env = unittest.begin(ctx)

    asserts.equals(env, '"a\\tb"', Star.gen("a\tb"))

    return unittest.end(env)

gen_tab_test = unittest.make(_gen_tab_test_impl)

def _indent_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = """
   {
      "key": [
         1,
         2,
         {
            "a": 1,
         },
      ],
      "flag": True,
      "name": "example",
      "a": "{foo}",
      "42": None,
   }
    """.strip()
    actual = Star.igen(_DICT, indent_count = 1, indent_size = 3)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

indent_test = unittest.make(_indent_test_impl)

def _inline_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "".join([
        "{",
        '"key": [1, 2, {"a": 1}], ',
        '"flag": True, ',
        '"name": "example", ',
        '"a": "{foo}", ',
        '"42": None',
        "}",
    ])
    actual = Star.gen(_DICT)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

inline_test = unittest.make(_inline_test_impl)

## --- list ---------------------------------------------

def _list_empty_test_impl(ctx):
    env = unittest.begin(ctx)

    ll = []
    expected = str(ll)
    actual = Star.igen(ll)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

list_empty_test = unittest.make(_list_empty_test_impl)

def _list_1_element_test_impl(ctx):
    env = unittest.begin(ctx)

    ll = ["a"]
    expected = """
[
    "a",
]
    """.strip()
    actual = Star.igen(ll)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

list_1_element_test = unittest.make(_list_1_element_test_impl)

def _list_2p_elements_test_impl(ctx):
    env = unittest.begin(ctx)

    ll = ["a", 1]
    expected = """
[
    "a",
    1,
]
    """.strip()
    actual = Star.igen(ll)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

list_2p_elements_test = unittest.make(_list_2p_elements_test_impl)

def _list_indent_test_impl(ctx):
    env = unittest.begin(ctx)

    ll = ["a"]
    expected = """
   [
      "a",
   ]
    """.strip()
    actual = Star.igen(ll, indent_count = 1, indent_size = 3)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

list_indent_test = unittest.make(_list_indent_test_impl)

def _list_quote_test_impl(ctx):
    env = unittest.begin(ctx)

    ll = ["a"]
    expected = """
[
    a,
]
    """.strip()
    actual = Star.igen(ll, quote_strings = False)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

list_quote_test = unittest.make(_list_quote_test_impl)

## --- tuple --------------------------------------------

def _tuple_empty_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "()", Star.gen(()))
    asserts.equals(env, "()", Star.igen(()))

    return unittest.end(env)

tuple_empty_test = unittest.make(_tuple_empty_test_impl)

def _tuple_1_element_inline_test_impl(ctx):
    """A single-element tuple must include a trailing comma."""
    env = unittest.begin(ctx)

    asserts.equals(env, "(1,)", Star.gen((1,)))

    return unittest.end(env)

tuple_1_element_inline_test = unittest.make(_tuple_1_element_inline_test_impl)

def _tuple_1_element_indent_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = """\
(
    1,
)"""
    actual = Star.igen((1,))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

tuple_1_element_indent_test = unittest.make(_tuple_1_element_indent_test_impl)

def _tuple_2p_elements_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "(1, 2)", Star.gen((1, 2)))

    return unittest.end(env)

tuple_2p_elements_test = unittest.make(_tuple_2p_elements_test_impl)

## --- dict ---------------------------------------------

def _dict_empty_test_impl(ctx):
    env = unittest.begin(ctx)

    d = {}
    expected = str(d)
    actual = Star.igen(d)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

dict_empty_test = unittest.make(_dict_empty_test_impl)

def _dict_1_element_test_impl(ctx):
    env = unittest.begin(ctx)

    d = {"a": "foo"}
    expected = """
{
    "a": "foo",
}
    """.strip()
    actual = Star.igen(d)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

dict_1_element_test = unittest.make(_dict_1_element_test_impl)

def _dict_2p_elements_test_impl(ctx):
    env = unittest.begin(ctx)

    d = {"a": "foo", 1: "bar"}
    expected = """
{
    "a": "foo",
    "1": "bar",
}
    """.strip()
    actual = Star.igen(d)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

dict_2p_elements_test = unittest.make(_dict_2p_elements_test_impl)

def _dict_indent_test_impl(ctx):
    env = unittest.begin(ctx)

    d = {"a": "foo"}
    expected = """
   {
      "a": "foo",
   }
    """.strip()
    actual = Star.igen(d, indent_count = 1, indent_size = 3)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

dict_indent_test = unittest.make(_dict_indent_test_impl)

def _dict_quote_test_impl(ctx):
    env = unittest.begin(ctx)

    d = {"a": "foo"}
    expected = """
{
    a: foo,
}
    """.strip()
    actual = Star.igen(d, quote_strings = False, quote_keys = False)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

dict_quote_test = unittest.make(_dict_quote_test_impl)

## --- depset ---------------------------------------------

def _depset_test_impl(ctx):
    env = unittest.begin(ctx)

    ds = depset([1, 2, 3])
    expected = """
depset([
    1,
    2,
    3,
])
    """.strip()
    actual = Star.igen(ds)

    asserts.equals(env, expected, actual)

    expected = "depset([1, 2, 3])"

    actual = Star.gen(ds)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

depset_test = unittest.make(_depset_test_impl)

## --- struct ---------------------------------------------

def _struct_test_impl(ctx):
    env = unittest.begin(ctx)

    s = struct(foo = "foo", bar = 42)
    expected = """
struct(
    foo = "foo",
    bar = 42,
)
    """.strip()
    actual = Star.igen(s)

    asserts.equals(env, expected, actual)

    expected = 'struct(foo = "foo", bar = 42)'

    actual = Star.gen(s)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

struct_test = unittest.make(_struct_test_impl)

## --- auto --------------------------------------------

def _auto_short_inline_test_impl(ctx):
    """A short value fits and renders inline."""
    env = unittest.begin(ctx)

    expected = '["a"]'
    actual = Star.auto(["a"])

    asserts.equals(env, expected, actual)

    return unittest.end(env)

auto_short_inline_test = unittest.make(_auto_short_inline_test_impl)

def _auto_long_multiline_test_impl(ctx):
    """A value longer than max_width falls back to indented rendering."""
    env = unittest.begin(ctx)

    expected = """\
[
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
]\
"""
    actual = Star.auto(["a" * 72], max_width = 72)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

auto_long_multiline_test = unittest.make(_auto_long_multiline_test_impl)

def _auto_respects_max_width_test_impl(ctx):
    """max_width = 4 forces multi-line for '[1, 2, 3]' (9 chars inline)."""
    env = unittest.begin(ctx)

    expected = """\
[
    1,
    2,
    3,
]\
"""
    actual = Star.auto([1, 2, 3], max_width = 4)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

auto_respects_max_width_test = unittest.make(_auto_respects_max_width_test_impl)

def _auto_fn_short_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "f(x = 1)"
    actual = Star.auto(Star.fn("f", x = 1))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

auto_fn_short_test = unittest.make(_auto_fn_short_test_impl)

def _auto_fn_long_test_impl(ctx):
    """A kwargs-heavy fn call breaks into multi-line past max_width."""
    env = unittest.begin(ctx)

    expected = """\
bzl_library(
    name = "defs",
    srcs = [
        "a.bzl",
        "b.bzl",
    ],
    deps = [
        "//very/long/path:a",
        "//very/long/path:b",
    ],
)\
"""
    actual = Star.auto(Star.fn(
        "bzl_library",
        name = "defs",
        srcs = ["a.bzl", "b.bzl"],
        deps = ["//very/long/path:a", "//very/long/path:b"],
    ))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

auto_fn_long_test = unittest.make(_auto_fn_long_test_impl)

def _auto_kwargs_pass_through_test_impl(ctx):
    """`quote_strings = False` reaches both inline and multi-line branches."""
    env = unittest.begin(ctx)

    # Short enough to stay inline under the default 80-char budget
    expected = "[A, B]"
    actual = Star.auto(["A", "B"], quote_strings = False)

    asserts.equals(env, expected, actual)

    # Force fallback to multi-line via tight budget; verify kwarg still applied
    expected = """\
[
    A,
    B,
]\
"""
    actual = Star.auto(["A", "B"], max_width = 4, quote_strings = False)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

auto_kwargs_pass_through_test = unittest.make(
    _auto_kwargs_pass_through_test_impl,
)

TEST_SUITE_TESTS = dict(
    escape = escape_test,
    gen_backslash = gen_backslash_test,
    gen_newline = gen_newline_test,
    gen_tab = gen_tab_test,
    indent = indent_test,
    inline = inline_test,
    # list
    list_empty = list_empty_test,
    list_1_element = list_1_element_test,
    list_2p_elements = list_2p_elements_test,
    list_quote = list_quote_test,
    list_indent = list_indent_test,
    # tuple
    tuple_empty = tuple_empty_test,
    tuple_1_element_inline = tuple_1_element_inline_test,
    tuple_1_element_indent = tuple_1_element_indent_test,
    tuple_2p_elements = tuple_2p_elements_test,
    # dict
    dict_empty = dict_empty_test,
    dict_1_element = dict_1_element_test,
    dict_2p_elements = dict_2p_elements_test,
    dict_quote = dict_quote_test,
    dict_indent = dict_indent_test,
    # depset
    depset = depset_test,
    # struct
    struct = struct_test,
    # auto
    auto_short_inline = auto_short_inline_test,
    auto_long_multiline = auto_long_multiline_test,
    auto_respects_max_width = auto_respects_max_width_test,
    auto_fn_short = auto_fn_short_test,
    auto_fn_long = auto_fn_long_test,
    auto_kwargs_pass_through = auto_kwargs_pass_through_test,
)
