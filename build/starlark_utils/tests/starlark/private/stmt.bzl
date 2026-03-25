"""Tests for statement builders and integration scenarios."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//starlark:starlark.bzl", Star = "starlark")

# ---------------------------------------------------------------------------
# assign
# ---------------------------------------------------------------------------

def _assign_simple_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "x = 42", Star.gen(Star.assign("x", 42)))
    return unittest.end(env)

assign_simple_test = unittest.make(_assign_simple_test_impl)

def _assign_string_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, 'name = "foo"', Star.gen(Star.assign("name", "foo")))
    return unittest.end(env)

assign_string_test = unittest.make(_assign_string_test_impl)

def _assign_list_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "xs = [1, 2, 3]",
        Star.gen(Star.assign("xs", [1, 2, 3])),
    )
    return unittest.end(env)

assign_list_test = unittest.make(_assign_list_test_impl)

def _assign_fn_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "x = compute()",
        Star.gen(Star.assign("x", Star.fn("compute"))),
    )
    return unittest.end(env)

assign_fn_test = unittest.make(_assign_fn_test_impl)

def _assign_expr_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "x = FOO + BAR",
        Star.gen(Star.assign("x", Star.expr("FOO + BAR"))),
    )
    return unittest.end(env)

assign_expr_test = unittest.make(_assign_expr_test_impl)

def _assign_nested_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
d = {
    "a": 1,
}\
"""
    asserts.equals(env, expected, Star.igen(Star.assign("d", {"a": 1})))
    return unittest.end(env)

assign_nested_test = unittest.make(_assign_nested_test_impl)

def _assign_in_block_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = "x = 1\ny = 2"
    actual = Star.gen(Star.block(Star.assign("x", 1), Star.assign("y", 2)))
    asserts.equals(env, expected, actual)
    return unittest.end(env)

assign_in_block_test = unittest.make(_assign_in_block_test_impl)

def _assign_in_file_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = '''\
"""Generated."""

x = 42
'''
    actual = Star.file(Star.gen(Star.assign("x", 42)), header = "Generated.")
    asserts.equals(env, expected, actual)
    return unittest.end(env)

assign_in_file_test = unittest.make(_assign_in_file_test_impl)

# ---------------------------------------------------------------------------
# return_
# ---------------------------------------------------------------------------

def _return_bare_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "return", Star.gen(Star.return_()))
    return unittest.end(env)

return_bare_test = unittest.make(_return_bare_test_impl)

def _return_value_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "return 42", Star.gen(Star.return_(42)))
    return unittest.end(env)

return_value_test = unittest.make(_return_value_test_impl)

def _return_expr_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "return result",
        Star.gen(Star.return_(Star.expr("result"))),
    )
    return unittest.end(env)

return_expr_test = unittest.make(_return_expr_test_impl)

def _return_fn_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "return compute()",
        Star.gen(Star.return_(Star.fn("compute"))),
    )
    return unittest.end(env)

return_fn_test = unittest.make(_return_fn_test_impl)

# ---------------------------------------------------------------------------
# block
# ---------------------------------------------------------------------------

def _block_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", Star.gen(Star.block()))
    return unittest.end(env)

block_empty_test = unittest.make(_block_empty_test_impl)

def _block_single_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "x = 1", Star.gen(Star.block(Star.assign("x", 1))))
    return unittest.end(env)

block_single_test = unittest.make(_block_single_test_impl)

def _block_multi_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = "x = 1\ny = 2"
    actual = Star.gen(Star.block(Star.assign("x", 1), Star.assign("y", 2)))
    asserts.equals(env, expected, actual)
    return unittest.end(env)

block_multi_test = unittest.make(_block_multi_test_impl)

def _block_indented_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = "    x = 1\n    y = 2"
    actual = Star.gen(
        Star.block(Star.assign("x", 1), Star.assign("y", 2)),
        indent_count = 1,
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

block_indented_test = unittest.make(_block_indented_test_impl)

def _block_in_file_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = '''\
"""Header."""

x = 1
y = 2
'''
    blk = Star.gen(Star.block(Star.assign("x", 1), Star.assign("y", 2)))
    actual = Star.file(blk, header = "Header.")
    asserts.equals(env, expected, actual)
    return unittest.end(env)

block_in_file_test = unittest.make(_block_in_file_test_impl)

# ---------------------------------------------------------------------------
# if_ / elif_ / else_
# ---------------------------------------------------------------------------

def _if_then_else_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
if x > 0:
    y = 1
else:
    y = 0\
"""
    actual = Star.gen(
        Star.if_(Star.expr("x > 0")).then(
            Star.assign("y", 1),
        ).else_(
            Star.assign("y", 0),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_then_else_test = unittest.make(_if_then_else_test_impl)

def _if_then_done_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
if x > 0:
    y = 1\
"""
    actual = Star.gen(
        Star.if_(Star.expr("x > 0")).then(
            Star.assign("y", 1),
        ).done,
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_then_done_test = unittest.make(_if_then_done_test_impl)

def _if_then_elif_else_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
if x > 0:
    handle_positive()
elif x == 0:
    handle_zero()
else:
    handle_negative()\
"""
    actual = Star.gen(
        Star.if_(Star.expr("x > 0")).then(
            Star.fn("handle_positive"),
        ).elif_(Star.expr("x == 0")).then(
            Star.fn("handle_zero"),
        ).else_(
            Star.fn("handle_negative"),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_then_elif_else_test = unittest.make(_if_then_elif_else_test_impl)

def _if_then_elif_elif_else_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
if x > 0:
    handle_positive()
elif x == 0:
    handle_zero()
elif x > -10:
    handle_small_negative()
else:
    handle_negative()\
"""
    actual = Star.gen(
        Star.if_(Star.expr("x > 0")).then(
            Star.fn("handle_positive"),
        ).elif_(Star.expr("x == 0")).then(
            Star.fn("handle_zero"),
        ).elif_(Star.expr("x > -10")).then(
            Star.fn("handle_small_negative"),
        ).else_(
            Star.fn("handle_negative"),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_then_elif_elif_else_test = unittest.make(_if_then_elif_elif_else_test_impl)

def _if_empty_body_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
if x > 0:
    pass\
"""
    actual = Star.gen(
        Star.if_(Star.expr("x > 0")).then().done,
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_empty_body_test = unittest.make(_if_empty_body_test_impl)

def _if_nested_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
if x > 0:
    if y > 0:
        handle_both()
    else:
        handle_x()\
"""
    actual = Star.gen(
        Star.if_(Star.expr("x > 0")).then(
            Star.if_(Star.expr("y > 0")).then(
                Star.fn("handle_both"),
            ).else_(
                Star.fn("handle_x"),
            ),
        ).done,
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_nested_test = unittest.make(_if_nested_test_impl)

def _if_with_fn_calls_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
if condition:
    setup()
    process(x, y)
    cleanup()\
"""
    actual = Star.gen(
        Star.if_(Star.expr("condition")).then(
            Star.fn("setup"),
            Star.fn("process", Star.expr("x"), Star.expr("y")),
            Star.fn("cleanup"),
        ).done,
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_with_fn_calls_test = unittest.make(_if_with_fn_calls_test_impl)

def _if_with_assign_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
if mode == "fast":
    x = compute()
    y = transform(x)\
"""
    actual = Star.gen(
        Star.if_(Star.expr('mode == "fast"')).then(
            Star.assign("x", Star.fn("compute")),
            Star.assign("y", Star.fn("transform", Star.expr("x"))),
        ).done,
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_with_assign_test = unittest.make(_if_with_assign_test_impl)

def _if_complex_cond_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
if x > 0 and y > 0:
    handle()\
"""
    actual = Star.gen(
        Star.if_(
            Star.binop("and", Star.expr("x > 0"), Star.expr("y > 0")),
        ).then(
            Star.fn("handle"),
        ).done,
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_complex_cond_test = unittest.make(_if_complex_cond_test_impl)

def _if_in_block_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
x = 1
if x > 0:
    process(x)
y = 2\
"""
    actual = Star.gen(Star.block(
        Star.assign("x", 1),
        Star.if_(Star.expr("x > 0")).then(
            Star.fn("process", Star.expr("x")),
        ).done,
        Star.assign("y", 2),
    ))
    asserts.equals(env, expected, actual)
    return unittest.end(env)

if_in_block_test = unittest.make(_if_in_block_test_impl)

# ---------------------------------------------------------------------------
# for_
# ---------------------------------------------------------------------------

def _for_simple_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
for item in items:
    process(item)\
"""
    actual = Star.gen(
        Star.for_(Star.expr("item"), Star.expr("items")).do_(
            Star.fn("process", Star.expr("item")),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

for_simple_test = unittest.make(_for_simple_test_impl)

def _for_multi_body_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
for item in items:
    setup(item)
    process(item)
    cleanup()\
"""
    actual = Star.gen(
        Star.for_(Star.expr("item"), Star.expr("items")).do_(
            Star.fn("setup", Star.expr("item")),
            Star.fn("process", Star.expr("item")),
            Star.fn("cleanup"),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

for_multi_body_test = unittest.make(_for_multi_body_test_impl)

def _for_empty_body_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
for item in items:
    pass\
"""
    actual = Star.gen(
        Star.for_(Star.expr("item"), Star.expr("items")).do_(),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

for_empty_body_test = unittest.make(_for_empty_body_test_impl)

def _for_nested_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
for x in xs:
    for y in ys:
        process(x, y)\
"""
    actual = Star.gen(
        Star.for_(Star.expr("x"), Star.expr("xs")).do_(
            Star.for_(Star.expr("y"), Star.expr("ys")).do_(
                Star.fn("process", Star.expr("x"), Star.expr("y")),
            ),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

for_nested_test = unittest.make(_for_nested_test_impl)

def _for_with_if_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
for item in items:
    if item > 0:
        process(item)\
"""
    actual = Star.gen(
        Star.for_(Star.expr("item"), Star.expr("items")).do_(
            Star.if_(Star.expr("item > 0")).then(
                Star.fn("process", Star.expr("item")),
            ).done,
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

for_with_if_test = unittest.make(_for_with_if_test_impl)

# ---------------------------------------------------------------------------
# def_
# ---------------------------------------------------------------------------

def _def_no_params_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
def f():
    return 42\
"""
    actual = Star.gen(Star.def_("f").body_(Star.return_(42)))
    asserts.equals(env, expected, actual)
    return unittest.end(env)

def_no_params_test = unittest.make(_def_no_params_test_impl)

def _def_with_params_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
def f(x, y):
    return x\
"""
    actual = Star.gen(
        Star.def_("f", "x", "y").body_(
            Star.return_(Star.expr("x")),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

def_with_params_test = unittest.make(_def_with_params_test_impl)

def _def_with_return_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
def compute():
    x = 42
    return x\
"""
    actual = Star.gen(
        Star.def_("compute").body_(
            Star.assign("x", 42),
            Star.return_(Star.expr("x")),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

def_with_return_test = unittest.make(_def_with_return_test_impl)

def _def_with_control_flow_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
def process(ctx):
    if ctx.attr.mode == "fast":
        handle_fast(ctx)
    for item in ctx.attr.items:
        process_item(item)\
"""
    actual = Star.gen(
        Star.def_("process", "ctx").body_(
            Star.if_(Star.expr('ctx.attr.mode == "fast"')).then(
                Star.fn("handle_fast", Star.expr("ctx")),
            ).done,
            Star.for_(Star.expr("item"), Star.expr("ctx.attr.items")).do_(
                Star.fn("process_item", Star.expr("item")),
            ),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

def_with_control_flow_test = unittest.make(_def_with_control_flow_test_impl)

def _def_empty_body_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
def f():
    pass\
"""
    actual = Star.gen(Star.def_("f").body_())
    asserts.equals(env, expected, actual)
    return unittest.end(env)

def_empty_body_test = unittest.make(_def_empty_body_test_impl)

def _def_full_rule_impl_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
def _impl(ctx):
    out = ctx.actions.declare_file("out.txt")
    return DefaultInfo(files = depset([out]))\
"""
    actual = Star.gen(
        Star.def_("_impl", "ctx").body_(
            Star.assign("out", Star.fn("ctx.actions.declare_file", "out.txt")),
            Star.return_(Star.fn(
                "DefaultInfo",
                files = Star.fn("depset", [Star.expr("out")]),
            )),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

def_full_rule_impl_test = unittest.make(_def_full_rule_impl_test_impl)

# ---------------------------------------------------------------------------
# Integration: combined statement constructs
# ---------------------------------------------------------------------------

def _nested_def_if_for_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
def process(ctx):
    for item in ctx.attr.items:
        if item.enabled:
            handle(item)\
"""
    actual = Star.gen(
        Star.def_("process", "ctx").body_(
            Star.for_(Star.expr("item"), Star.expr("ctx.attr.items")).do_(
                Star.if_(Star.expr("item.enabled")).then(
                    Star.fn("handle", Star.expr("item")),
                ).done,
            ),
        ),
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

nested_def_if_for_test = unittest.make(_nested_def_if_for_test_impl)

def _block_mixed_statements_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
x = compute()
if x > 0:
    process(x)
else:
    handle_error()
for item in items:
    collect(item)
return result\
"""
    actual = Star.gen(Star.block(
        Star.assign("x", Star.fn("compute")),
        Star.if_(Star.expr("x > 0")).then(
            Star.fn("process", Star.expr("x")),
        ).else_(
            Star.fn("handle_error"),
        ),
        Star.for_(Star.expr("item"), Star.expr("items")).do_(
            Star.fn("collect", Star.expr("item")),
        ),
        Star.return_(Star.expr("result")),
    ))
    asserts.equals(env, expected, actual)
    return unittest.end(env)

block_mixed_statements_test = unittest.make(_block_mixed_statements_test_impl)

def _file_with_statements_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = '''\
"""Generated."""

def _impl(ctx):
    return DefaultInfo()
'''
    actual = Star.file(
        Star.gen(
            Star.def_("_impl", "ctx").body_(
                Star.return_(Star.fn("DefaultInfo")),
            ),
        ),
        header = "Generated.",
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

file_with_statements_test = unittest.make(_file_with_statements_test_impl)

def _statement_indent_count_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = """\
    x = 1
    if x > 0:
        process(x)\
"""
    actual = Star.gen(
        Star.block(
            Star.assign("x", 1),
            Star.if_(Star.expr("x > 0")).then(
                Star.fn("process", Star.expr("x")),
            ).done,
        ),
        indent_count = 1,
    )
    asserts.equals(env, expected, actual)
    return unittest.end(env)

statement_indent_count_test = unittest.make(_statement_indent_count_test_impl)

def _full_bzl_file_test_impl(ctx):
    env = unittest.begin(ctx)
    expected = '''\
"""Generated by example."""

def _impl(ctx):
    out = ctx.actions.declare_file("out.txt")
    return DefaultInfo(files = depset([out]))
'''
    impl_def = Star.gen(
        Star.def_("_impl", "ctx").body_(
            Star.assign("out", Star.fn("ctx.actions.declare_file", "out.txt")),
            Star.return_(Star.fn(
                "DefaultInfo",
                files = Star.fn("depset", [Star.expr("out")]),
            )),
        ),
    )
    actual = Star.file(impl_def, header = "Generated by example.")
    asserts.equals(env, expected, actual)
    return unittest.end(env)

full_bzl_file_test = unittest.make(_full_bzl_file_test_impl)

TEST_SUITE_TESTS = dict(
    # assign
    assign_simple = assign_simple_test,
    assign_string = assign_string_test,
    assign_list = assign_list_test,
    assign_fn = assign_fn_test,
    assign_expr = assign_expr_test,
    assign_nested = assign_nested_test,
    assign_in_block = assign_in_block_test,
    assign_in_file = assign_in_file_test,
    # return_
    return_bare = return_bare_test,
    return_value = return_value_test,
    return_expr = return_expr_test,
    return_fn = return_fn_test,
    # block
    block_empty = block_empty_test,
    block_single = block_single_test,
    block_multi = block_multi_test,
    block_indented = block_indented_test,
    block_in_file = block_in_file_test,
    # if_ / elif_ / else_
    if_then_else = if_then_else_test,
    if_then_done = if_then_done_test,
    if_then_elif_else = if_then_elif_else_test,
    if_then_elif_elif_else = if_then_elif_elif_else_test,
    if_empty_body = if_empty_body_test,
    if_nested = if_nested_test,
    if_with_fn_calls = if_with_fn_calls_test,
    if_with_assign = if_with_assign_test,
    if_complex_cond = if_complex_cond_test,
    if_in_block = if_in_block_test,
    # for_
    for_simple = for_simple_test,
    for_multi_body = for_multi_body_test,
    for_empty_body = for_empty_body_test,
    for_nested = for_nested_test,
    for_with_if = for_with_if_test,
    # def_
    def_no_params = def_no_params_test,
    def_with_params = def_with_params_test,
    def_with_return = def_with_return_test,
    def_with_control_flow = def_with_control_flow_test,
    def_empty_body = def_empty_body_test,
    def_full_rule_impl = def_full_rule_impl_test,
    # integration
    nested_def_if_for = nested_def_if_for_test,
    block_mixed_statements = block_mixed_statements_test,
    file_with_statements = file_with_statements_test,
    statement_indent_count = statement_indent_count_test,
    full_bzl_file = full_bzl_file_test,
)
