"""Tests for expression builders, string literals, and ref alias."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//starlark:starlark.bzl", Star = "starlark")
load("//tests:mock.bzl", "mock")

## --- expr / ref alias --------------------------------

def _expr_simple_test_impl(ctx):
    """expr renders the given text verbatim (not quoted)."""
    env = unittest.begin(ctx)

    expected = "a + b"
    actual = Star.gen(Star.expr("a + b"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

expr_simple_test = unittest.make(_expr_simple_test_impl)

def _expr_in_list_test_impl(ctx):
    """expr composes inside containers, same as ref."""
    env = unittest.begin(ctx)

    expected = "[CFGS.keys(), EXTS]"
    actual = Star.gen([Star.expr("CFGS.keys()"), Star.expr("EXTS")])

    asserts.equals(env, expected, actual)

    return unittest.end(env)

expr_in_list_test = unittest.make(_expr_in_list_test_impl)

def _expr_ending_with_bracket_test_impl(ctx):
    """An expr whose text ends with '[' must not confuse the comma logic."""
    env = unittest.begin(ctx)

    asserts.equals(env, "[foo[, 1]", Star.gen([Star.expr("foo["), 1]))
    asserts.equals(env, "(foo(, 1)", Star.gen((Star.expr("foo("), 1)))
    asserts.equals(
        env,
        '{"a": foo{, "b": 1}',
        Star.gen({"a": Star.expr("foo{"), "b": 1}),
    )

    return unittest.end(env)

expr_ending_with_bracket_test = unittest.make(
    _expr_ending_with_bracket_test_impl,
)

def _expr_ending_with_bracket_indent_test_impl(ctx):
    """Same as above but indented: comma and newline must appear."""
    env = unittest.begin(ctx)

    expected = """\
[
    foo[,
    1,
]"""
    actual = Star.igen([Star.expr("foo["), 1])

    asserts.equals(env, expected, actual)

    return unittest.end(env)

expr_ending_with_bracket_indent_test = unittest.make(
    _expr_ending_with_bracket_indent_test_impl,
)

def _fn_expr_ending_with_paren_test_impl(ctx):
    """Positional expr ending with '(' must not confuse fn comma logic."""
    env = unittest.begin(ctx)

    asserts.equals(env, "f(g(, 1)", Star.gen(Star.fn("f", Star.expr("g("), 1)))

    return unittest.end(env)

fn_expr_ending_with_paren_test = unittest.make(
    _fn_expr_ending_with_paren_test_impl,
)

def _expr_ref_alias_test_impl(ctx):
    """ref is an alias for expr."""
    env = unittest.begin(ctx)

    asserts.equals(env, Star.expr("X"), Star.ref("X"))
    asserts.equals(env, Star.expr("a.b[0]"), Star.ref("a.b[0]"))

    return unittest.end(env)

expr_ref_alias_test = unittest.make(_expr_ref_alias_test_impl)

## --- comment -----------------------------------------

def _comment_simple_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "# hello"
    actual = Star.gen(Star.comment("hello"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

comment_simple_test = unittest.make(_comment_simple_test_impl)

def _comment_multiline_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "# a\n# b\n# c"
    actual = Star.gen(Star.comment("a\nb\nc"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

comment_multiline_test = unittest.make(_comment_multiline_test_impl)

def _comment_blank_line_test_impl(ctx):
    """Blank lines render as `#` with no trailing space."""
    env = unittest.begin(ctx)

    expected = "# a\n#\n# b"
    actual = Star.gen(Star.comment("a\n\nb"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

comment_blank_line_test = unittest.make(_comment_blank_line_test_impl)

def _comment_remove_prefix_test_impl(ctx):
    """A literal written aligned with the code renders flush against the `#`."""
    env = unittest.begin(ctx)

    expected = "# a\n# b"
    actual = Star.gen(Star.comment("""\
        a
        b
    """))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

comment_remove_prefix_test = unittest.make(_comment_remove_prefix_test_impl)

def _comment_remove_prefix_keeps_relative_test_impl(ctx):
    """Only the SHARED indentation goes: the block keeps its own shape."""
    env = unittest.begin(ctx)

    expected = "# a\n#   b\n#\n# c"
    actual = Star.gen(Star.comment("""\
        a
          b

        c
    """))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

comment_remove_prefix_keeps_relative_test = unittest.make(
    _comment_remove_prefix_keeps_relative_test_impl,
)

def _comment_remove_prefix_off_test_impl(ctx):
    """With it off, the indentation is part of the comment."""
    env = unittest.begin(ctx)

    expected = "#     a\n#     b"
    actual = Star.gen(Star.comment("    a\n    b", remove_prefix = False))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

comment_remove_prefix_off_test = unittest.make(
    _comment_remove_prefix_off_test_impl,
)

def _comment_remove_prefix_flush_left_test_impl(ctx):
    """A flush-left body has no shared indentation, so nothing changes."""
    env = unittest.begin(ctx)

    expected = "# a\n#   b"
    actual = Star.gen(Star.comment("a\n  b"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

comment_remove_prefix_flush_left_test = unittest.make(
    _comment_remove_prefix_flush_left_test_impl,
)

def _comment_in_file_test_impl(ctx):
    """Integration: a comment slots into Star.file like any other part."""
    env = unittest.begin(ctx)

    expected = "# Auto-generated from X\n\nFOO = 1\n"
    actual = Star.file(
        Star.comment("Auto-generated from X"),
        "FOO = 1",
    )

    asserts.equals(env, expected, actual)

    return unittest.end(env)

comment_in_file_test = unittest.make(_comment_in_file_test_impl)

## --- rstr / rtstr ------------------------------------

def _rstr_simple_test_impl(ctx):
    """Backslashes in input stay literal: no escape processing."""
    env = unittest.begin(ctx)

    expected = 'r"foo\\d+"'
    actual = Star.gen(Star.rstr("foo\\d+"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rstr_simple_test = unittest.make(_rstr_simple_test_impl)

def _rstr_path_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'r"C:\\Users\\x"'
    actual = Star.gen(Star.rstr("C:\\Users\\x"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rstr_path_test = unittest.make(_rstr_path_test_impl)

def _rstr_rejects_quote_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'rstr: text contains a double-quote; use rtstr (if no """) or tstr'
    actual = Star.rstr('a"b', _fail = mock.fail)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rstr_rejects_quote_test = unittest.make(_rstr_rejects_quote_test_impl)

def _rstr_rejects_trailing_backslash_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "rstr: raw literals cannot end with an odd number of backslashes; use tstr instead"
    actual = Star.rstr("foo\\", _fail = mock.fail)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rstr_rejects_trailing_backslash_test = unittest.make(
    _rstr_rejects_trailing_backslash_test_impl,
)

def _rstr_allows_even_trailing_backslash_test_impl(ctx):
    """Even count of trailing backslashes is valid in raw strings."""
    env = unittest.begin(ctx)

    result = Star.rstr("foo\\\\", _fail = mock.fail)
    asserts.true(
        env,
        type(result) == "dict",
        "expected node dict, got: %s" % result,
    )
    asserts.equals(env, 'r"foo\\\\"', Star.gen(result))

    return unittest.end(env)

rstr_allows_even_trailing_backslash_test = unittest.make(
    _rstr_allows_even_trailing_backslash_test_impl,
)

def _rstr_rejects_newline_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "rstr: raw single-line literals cannot contain newlines; use rtstr"
    actual = Star.rstr("a\nb", _fail = mock.fail)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rstr_rejects_newline_test = unittest.make(_rstr_rejects_newline_test_impl)

def _rtstr_simple_test_impl(ctx):
    """Backslash-n in input stays literal (not interpreted as newline)."""
    env = unittest.begin(ctx)

    expected = 'r"""foo\\nbar"""'
    actual = Star.gen(Star.rtstr("foo\\nbar"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rtstr_simple_test = unittest.make(_rtstr_simple_test_impl)

def _rtstr_multiline_test_impl(ctx):
    """Real newlines are allowed in triple-quoted form."""
    env = unittest.begin(ctx)

    expected = 'r"""line1\nline2"""'
    actual = Star.gen(Star.rtstr("line1\nline2"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rtstr_multiline_test = unittest.make(_rtstr_multiline_test_impl)

def _rtstr_allows_single_quote_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = 'r"""has "inside" ok"""'
    actual = Star.gen(Star.rtstr('has "inside" ok'))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rtstr_allows_single_quote_test = unittest.make(
    _rtstr_allows_single_quote_test_impl,
)

def _rtstr_rejects_triple_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "rtstr: text contains a triple-quote; use tstr instead"
    actual = Star.rtstr('a"""b', _fail = mock.fail)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rtstr_rejects_triple_test = unittest.make(_rtstr_rejects_triple_test_impl)

def _rtstr_rejects_trailing_quote_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "rtstr: raw triple literals cannot end with a double-quote; use tstr"
    actual = Star.rtstr('hello"', _fail = mock.fail)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rtstr_rejects_trailing_quote_test = unittest.make(
    _rtstr_rejects_trailing_quote_test_impl,
)

def _rtstr_rejects_trailing_backslash_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "rtstr: raw literals cannot end with an odd number of backslashes; use tstr instead"
    actual = Star.rtstr("foo\\", _fail = mock.fail)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

rtstr_rejects_trailing_backslash_test = unittest.make(
    _rtstr_rejects_trailing_backslash_test_impl,
)

def _rtstr_allows_even_trailing_backslash_test_impl(ctx):
    """Even count of trailing backslashes is valid in raw triple strings."""
    env = unittest.begin(ctx)

    result = Star.rtstr("foo\\\\", _fail = mock.fail)
    asserts.true(
        env,
        type(result) == "dict",
        "expected node dict, got: %s" % result,
    )
    asserts.equals(env, 'r"""foo\\\\"""', Star.gen(result))

    return unittest.end(env)

rtstr_allows_even_trailing_backslash_test = unittest.make(
    _rtstr_allows_even_trailing_backslash_test_impl,
)

## --- ternary -----------------------------------------

def _ternary_simple_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "1 if x > 0 else -1"
    actual = Star.gen(Star.ternary(Star.expr("x > 0"), 1, -1))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ternary_simple_test = unittest.make(_ternary_simple_test_impl)

def _ternary_strings_test_impl(ctx):
    """String operands get quoted."""
    env = unittest.begin(ctx)

    expected = '"yes" if ok else "no"'
    actual = Star.gen(Star.ternary(Star.expr("ok"), "yes", "no"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ternary_strings_test = unittest.make(_ternary_strings_test_impl)

def _ternary_nested_test_impl(ctx):
    """Nested ternary composes directly; inner is already a node."""
    env = unittest.begin(ctx)

    expected = "1 if b else 2 if a else 3"
    actual = Star.gen(Star.ternary(
        Star.expr("a"),
        Star.ternary(Star.expr("b"), 1, 2),
        3,
    ))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ternary_nested_test = unittest.make(_ternary_nested_test_impl)

## --- tstr / docstring alias --------------------------

def _tstr_simple_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = '"""hello"""'
    actual = Star.gen(Star.tstr("hello"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

tstr_simple_test = unittest.make(_tstr_simple_test_impl)

def _tstr_escapes_test_impl(ctx):
    """tstr uses the same escape logic as docstring."""
    env = unittest.begin(ctx)

    expected = '"""a\\"b"""'
    actual = Star.gen(Star.tstr('a"b'))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

tstr_escapes_test = unittest.make(_tstr_escapes_test_impl)

def _tstr_triple_double_uses_single_test_impl(ctx):
    """When text contains triple-double-quotes, tstr uses triple-single-quotes."""
    env = unittest.begin(ctx)

    asserts.equals(env, "'''\"\"\"'''", Star.gen(Star.tstr('"""')))
    asserts.equals(env, "'''a\"\"\"b'''", Star.gen(Star.tstr('a"""b')))

    return unittest.end(env)

tstr_triple_double_uses_single_test = unittest.make(
    _tstr_triple_double_uses_single_test_impl,
)

def _tstr_both_triple_falls_back_test_impl(ctx):
    """When text contains both triple-double and triple-single, escape."""
    env = unittest.begin(ctx)

    text = '"""' + "'''"
    result = Star.gen(Star.tstr(text))

    asserts.true(
        env,
        result.startswith('"""'),
        "should use triple-double: %s" % result,
    )
    asserts.true(
        env,
        "'''" in result,
        "single-quotes should be literal: %s" % result,
    )

    return unittest.end(env)

tstr_both_triple_falls_back_test = unittest.make(
    _tstr_both_triple_falls_back_test_impl,
)

def _tstr_single_quote_in_double_test_impl(ctx):
    """Single quotes in text don't trigger the switch to triple-single-quotes."""
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "\"\"\"it's fine\"\"\"",
        Star.gen(Star.tstr("it's fine")),
    )

    return unittest.end(env)

tstr_single_quote_in_double_test = unittest.make(
    _tstr_single_quote_in_double_test_impl,
)

def _tstr_docstring_alias_test_impl(ctx):
    """docstring is an alias for tstr."""
    env = unittest.begin(ctx)

    asserts.equals(env, Star.tstr("x"), Star.docstring("x"))
    asserts.equals(env, Star.tstr("a\nb"), Star.docstring("a\nb"))
    asserts.equals(env, Star.tstr('"""'), Star.docstring('"""'))

    return unittest.end(env)

tstr_docstring_alias_test = unittest.make(_tstr_docstring_alias_test_impl)

## --- docstring ---------------------------------------

def _docstring_simple_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = '"""hello"""'
    actual = Star.gen(Star.docstring("hello"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

docstring_simple_test = unittest.make(_docstring_simple_test_impl)

def _docstring_multiline_test_impl(ctx):
    """Triple-quoted literals allow raw newlines; no escaping needed."""
    env = unittest.begin(ctx)

    expected = '"""a\nb\nc"""'
    actual = Star.gen(Star.docstring("a\nb\nc"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

docstring_multiline_test = unittest.make(_docstring_multiline_test_impl)

def _docstring_embedded_quotes_test_impl(ctx):
    """Each " in input is escaped to \\" so the literal round-trips."""
    env = unittest.begin(ctx)

    expected = '"""he said \\"hi\\""""'
    actual = Star.gen(Star.docstring('he said "hi"'))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

docstring_embedded_quotes_test = unittest.make(
    _docstring_embedded_quotes_test_impl,
)

def _docstring_triple_quote_test_impl(ctx):
    """Triple-quote sequences in input switch to triple-single-quotes."""
    env = unittest.begin(ctx)

    expected = "'''\"\"\"'''"
    actual = Star.gen(Star.docstring('"""'))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

docstring_triple_quote_test = unittest.make(_docstring_triple_quote_test_impl)

def _docstring_empty_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = '""""""'
    actual = Star.gen(Star.docstring(""))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

docstring_empty_test = unittest.make(_docstring_empty_test_impl)

def _docstring_backslash_test_impl(ctx):
    """Backslashes are doubled so the literal round-trips."""
    env = unittest.begin(ctx)

    expected = '"""a\\\\b"""'
    actual = Star.gen(Star.docstring("a\\b"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

docstring_backslash_test = unittest.make(_docstring_backslash_test_impl)

def _docstring_generated_by_test_impl(ctx):
    """Realistic top-of-file header emits as a plain triple-quoted literal."""
    env = unittest.begin(ctx)

    expected = '"""Generated by monoext/private/pg. DO NOT EDIT."""'
    actual = Star.gen(
        Star.docstring("Generated by monoext/private/pg. DO NOT EDIT."),
    )

    asserts.equals(env, expected, actual)

    return unittest.end(env)

docstring_generated_by_test = unittest.make(_docstring_generated_by_test_impl)

## --- binop -------------------------------------------

def _binop_arith_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "1 + 2"
    actual = Star.gen(Star.binop("+", 1, 2))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

binop_arith_test = unittest.make(_binop_arith_test_impl)

def _binop_variadic_test_impl(ctx):
    """Three or more operands all join with the same separator."""
    env = unittest.begin(ctx)

    expected = "1 + 2 + 3"
    actual = Star.gen(Star.binop("+", 1, 2, 3))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

binop_variadic_test = unittest.make(_binop_variadic_test_impl)

def _binop_logical_test_impl(ctx):
    """Word operators (and/or/not) work the same as symbols."""
    env = unittest.begin(ctx)

    expected = "a and b"
    actual = Star.gen(Star.binop("and", Star.expr("a"), Star.expr("b")))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

binop_logical_test = unittest.make(_binop_logical_test_impl)

def _binop_strings_test_impl(ctx):
    """String operands get quoted (valid string concatenation)."""
    env = unittest.begin(ctx)

    expected = '"foo" + "bar"'
    actual = Star.gen(Star.binop("+", "foo", "bar"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

binop_strings_test = unittest.make(_binop_strings_test_impl)

def _binop_mixed_test_impl(ctx):
    """Mix expr() (bare) with literals in the same binop."""
    env = unittest.begin(ctx)

    expected = "x + 1"
    actual = Star.gen(Star.binop("+", Star.expr("x"), 1))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

binop_mixed_test = unittest.make(_binop_mixed_test_impl)

def _binop_fails_on_one_operand_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "binop requires at least 2 operands, got 1"
    actual = Star.binop("+", 1, _fail = mock.fail)

    asserts.equals(env, expected, actual)

    return unittest.end(env)

binop_fails_on_one_operand_test = unittest.make(
    _binop_fails_on_one_operand_test_impl,
)

## --- listcomp / dictcomp -----------------------------

def _listcomp_simple_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "[x * 2 for x in xs]"
    actual = Star.gen(Star.listcomp(
        Star.expr("x * 2"),
        Star.expr("x"),
        Star.expr("xs"),
    ))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

listcomp_simple_test = unittest.make(_listcomp_simple_test_impl)

def _listcomp_with_cond_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "[x for x in xs if x > 0]"
    actual = Star.gen(Star.listcomp(
        Star.expr("x"),
        Star.expr("x"),
        Star.expr("xs"),
        cond = Star.expr("x > 0"),
    ))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

listcomp_with_cond_test = unittest.make(_listcomp_with_cond_test_impl)

def _listcomp_quoted_iter_test_impl(ctx):
    """A real list passed as iter_ gets rendered inline (quoted strings)."""
    env = unittest.begin(ctx)

    expected = '[x for x in ["a", "b"]]'
    actual = Star.gen(Star.listcomp(
        Star.expr("x"),
        Star.expr("x"),
        ["a", "b"],
    ))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

listcomp_quoted_iter_test = unittest.make(_listcomp_quoted_iter_test_impl)

def _dictcomp_simple_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "{k: v for k, v in items.items()}"
    actual = Star.gen(Star.dictcomp(
        Star.expr("k"),
        Star.expr("v"),
        Star.expr("k, v"),
        Star.expr("items.items()"),
    ))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

dictcomp_simple_test = unittest.make(_dictcomp_simple_test_impl)

def _dictcomp_with_cond_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "{k: v for k, v in items.items() if v}"
    actual = Star.gen(Star.dictcomp(
        Star.expr("k"),
        Star.expr("v"),
        Star.expr("k, v"),
        Star.expr("items.items()"),
        cond = Star.expr("v"),
    ))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

dictcomp_with_cond_test = unittest.make(_dictcomp_with_cond_test_impl)

## --- ref ---------------------------------------------

def _ref_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "OPTIONS"
    actual = Star.gen(Star.ref("OPTIONS"))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ref_test = unittest.make(_ref_test_impl)

def _ref_in_dict_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = '{"x": Y}'
    actual = Star.gen({"x": Star.ref("Y")})

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ref_in_dict_test = unittest.make(_ref_in_dict_test_impl)

def _ref_in_fn_kwarg_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "f(x = Y)"
    actual = Star.gen(Star.fn("f", x = Star.ref("Y")))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ref_in_fn_kwarg_test = unittest.make(_ref_in_fn_kwarg_test_impl)

def _ref_in_fn_positional_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "f(A, B)"
    actual = Star.gen(Star.fn("f", Star.ref("A"), Star.ref("B")))

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ref_in_fn_positional_test = unittest.make(_ref_in_fn_positional_test_impl)

def _ref_in_list_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "[A, B]"
    actual = Star.gen([Star.ref("A"), Star.ref("B")])

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ref_in_list_test = unittest.make(_ref_in_list_test_impl)

def _ref_in_assignments_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = "MESON_OPTIONS = OPTIONS"
    actual = Star.assignments({"MESON_OPTIONS": Star.ref("OPTIONS")})

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ref_in_assignments_test = unittest.make(_ref_in_assignments_test_impl)

def _ref_assignments_mixed_test_impl(ctx):
    """Refs coexist with quoted strings in the same assignments() call."""
    env = unittest.begin(ctx)

    expected = """\
FOO = "bar"
MESON_OPTIONS = OPTIONS\
"""
    actual = Star.assignments(
        [("FOO", "bar"), ("MESON_OPTIONS", Star.ref("OPTIONS"))],
        inline = False,
    )

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ref_assignments_mixed_test = unittest.make(_ref_assignments_mixed_test_impl)

def _ref_indent_test_impl(ctx):
    env = unittest.begin(ctx)

    expected = """\
[
    A,
    B,
]"""
    actual = Star.igen([Star.ref("A"), Star.ref("B")])

    asserts.equals(env, expected, actual)

    return unittest.end(env)

ref_indent_test = unittest.make(_ref_indent_test_impl)

TEST_SUITE_TESTS = dict(
    # expr (ref alias)
    expr_simple = expr_simple_test,
    expr_in_list = expr_in_list_test,
    expr_ending_with_bracket = expr_ending_with_bracket_test,
    expr_ending_with_bracket_indent = expr_ending_with_bracket_indent_test,
    fn_expr_ending_with_paren = fn_expr_ending_with_paren_test,
    expr_ref_alias = expr_ref_alias_test,
    # comment
    comment_simple = comment_simple_test,
    comment_multiline = comment_multiline_test,
    comment_blank_line = comment_blank_line_test,
    comment_in_file = comment_in_file_test,
    comment_remove_prefix = comment_remove_prefix_test,
    comment_remove_prefix_flush_left = comment_remove_prefix_flush_left_test,
    comment_remove_prefix_keeps_relative = comment_remove_prefix_keeps_relative_test,
    comment_remove_prefix_off = comment_remove_prefix_off_test,
    # rstr / rtstr
    rstr_simple = rstr_simple_test,
    rstr_path = rstr_path_test,
    rstr_rejects_quote = rstr_rejects_quote_test,
    rstr_rejects_trailing_backslash = rstr_rejects_trailing_backslash_test,
    rstr_allows_even_trailing_backslash = rstr_allows_even_trailing_backslash_test,
    rstr_rejects_newline = rstr_rejects_newline_test,
    rtstr_simple = rtstr_simple_test,
    rtstr_multiline = rtstr_multiline_test,
    rtstr_allows_single_quote = rtstr_allows_single_quote_test,
    rtstr_rejects_triple = rtstr_rejects_triple_test,
    rtstr_rejects_trailing_quote = rtstr_rejects_trailing_quote_test,
    rtstr_rejects_trailing_backslash = rtstr_rejects_trailing_backslash_test,
    rtstr_allows_even_trailing_backslash = rtstr_allows_even_trailing_backslash_test,
    # ternary
    ternary_simple = ternary_simple_test,
    ternary_strings = ternary_strings_test,
    ternary_nested = ternary_nested_test,
    # tstr (docstring alias)
    tstr_simple = tstr_simple_test,
    tstr_escapes = tstr_escapes_test,
    tstr_triple_double_uses_single = tstr_triple_double_uses_single_test,
    tstr_both_triple_falls_back = tstr_both_triple_falls_back_test,
    tstr_single_quote_in_double = tstr_single_quote_in_double_test,
    tstr_docstring_alias = tstr_docstring_alias_test,
    # docstring
    docstring_simple = docstring_simple_test,
    docstring_multiline = docstring_multiline_test,
    docstring_embedded_quotes = docstring_embedded_quotes_test,
    docstring_triple_quote = docstring_triple_quote_test,
    docstring_empty = docstring_empty_test,
    docstring_backslash = docstring_backslash_test,
    docstring_generated_by = docstring_generated_by_test,
    # binop
    binop_arith = binop_arith_test,
    binop_variadic = binop_variadic_test,
    binop_logical = binop_logical_test,
    binop_strings = binop_strings_test,
    binop_mixed = binop_mixed_test,
    binop_fails_on_one_operand = binop_fails_on_one_operand_test,
    # listcomp / dictcomp
    listcomp_simple = listcomp_simple_test,
    listcomp_with_cond = listcomp_with_cond_test,
    listcomp_quoted_iter = listcomp_quoted_iter_test,
    dictcomp_simple = dictcomp_simple_test,
    dictcomp_with_cond = dictcomp_with_cond_test,
    # ref
    ref = ref_test,
    ref_in_dict = ref_in_dict_test,
    ref_in_fn_kwarg = ref_in_fn_kwarg_test,
    ref_in_fn_positional = ref_in_fn_positional_test,
    ref_in_list = ref_in_list_test,
    ref_in_assignments = ref_in_assignments_test,
    ref_assignments_mixed = ref_assignments_mixed_test,
    ref_indent = ref_indent_test,
)
