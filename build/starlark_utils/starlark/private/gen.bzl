"""Core Starlark source code renderer."""

load("//starlark/private:fn.bzl", "fn")
load("//starlark/private:node.bzl", "SENTINEL")

# Starlark prohibits recursion and while loops, so gen() uses an explicit stack
# driven by a for loop. range() caps at signed 32-bit ((1 << 31) - 1):
# https://github.com/bazelbuild/bazel/blob/37654e5/src/main/java/net/starlark/java/eval/RangeList.java#L88-L91
MAX_ITERATIONS = (1 << 31) - 2

BRACKETS = {
    "close": {
        "dict": "}",
        "list": "]",
        "tuple": ")",
    },
    "open": {
        "dict": "{",
        "list": "[",
        "tuple": "(",
    },
}

def escape(s):
    return s.replace("\\", "\\\\").replace("\n", "\\n")

def has_odd_trailing_backslashes(s):
    """True when s ends with an odd number of backslashes.

    Args:
        s: string to check.

    Returns:
        True if the trailing backslash count is odd.
    """
    count = 0
    for i in range(len(s) - 1, -1, -1):
        if s[i] == "\\":
            count += 1
        else:
            break
    return count % 2 == 1

def is_container(value):
    """Check if value is a plain container.

    Plain containers are: list, tuple or dict without the node sentinel.
    """
    t = type(value)

    return (
        t in ("list", "tuple") or
        t == "dict" and SENTINEL not in value
    )

def _gen(
        value,
        indent = False,
        indent_count = 0,
        indent_size = 4,
        quote_strings = True,
        quote_keys = True):
    """Generate a Starlark source string representation of a value.

    Supports nested data structures, including `list`, `tuple`, `dict`,
    `depset`, and `struct`, and applies quoting/formatting as configured.

    Args:
        value: The value to render. Can be any Starlark-compatible type.
        indent: If `True`, pretty-print with indentation.
        indent_count: Base indentation level.
        indent_size: Number of spaces per indent level.
        quote_strings: Whether to quote `string` values.
        quote_keys: Whether to quote `dict` keys.

    Returns:
        A Starlark-compatible source string.
    """
    result = []
    tab = " " * indent_size
    stack = [(value, type(value), None)]
    state = {"depth": indent_count}

    def _emit(text):
        result.append(text)

    def _emit_sep(is_first):
        if not is_first:
            _emit(",\n" if indent else ", ")
        elif indent:
            _emit("\n")
        if indent:
            _emit(tab * state["depth"])

    def _emit_close(closer):
        if indent:
            _emit(",\n")
            state["depth"] -= 1
            _emit(tab * state["depth"])
        _emit(closer)

    def _open_group(opener):
        _emit(opener)
        if indent:
            state["depth"] += 1

    def _push_close(closer, item_type):
        stack.append((closer, item_type, "close"))

    def _push_items(iterable, item_type, first_ctx = "item_first", rest_ctx = "item"):
        stack.extend(reversed([
            (item, item_type, first_ctx if idx == 0 else rest_ctx)
            for idx, item in enumerate(iterable)
        ]))

    def _push_body(stmts):
        if not stmts:
            stack.append(
                ("\n%spass" % (tab * (state["depth"] + 1)), "string", "raw"),
            )
            return
        stack.append((None, None, "dedent"))
        for idx in range(len(stmts) - 1, -1, -1):
            stack.append((stmts[idx], type(stmts[idx]), "stmt"))
        stack.append((None, None, "indent"))

    def _iteritems(container, container_type):
        return container.items() if container_type == "dict" else container

    def _render_container(current, current_type):
        opener = BRACKETS["open"][current_type]
        closer = BRACKETS["close"][current_type]

        if not current:
            _emit(opener + closer)
            return

        if current_type == "tuple" and not indent and len(current) == 1:
            closer = ",)"

        _open_group(opener)
        _push_close(closer, current_type)
        _push_items(_iteritems(current, current_type), current_type)

    def _render_merged_fn(fn_name, arg):
        arg_type = type(arg)
        opener = BRACKETS["open"][arg_type]
        closer = BRACKETS["close"][arg_type] + ")"

        if not arg:
            _emit("%s(%s%s" % (fn_name, opener, closer))
            return

        _open_group("%s(%s" % (fn_name, opener))
        _push_close(closer, arg_type)
        _push_items(_iteritems(arg, arg_type), arg_type)

    def _render_fn_call(n):
        fn_name = n["name"]
        positional = n.get("args", ())
        kwargs = n.get("kwargs", {})

        if not positional and not kwargs:
            _emit("%s()" % fn_name)
            return

        if len(positional) == 1 and not kwargs and is_container(positional[0]):
            _render_merged_fn(fn_name, positional[0])
            return

        _open_group("%s(" % fn_name)
        _push_close(")", "fn")
        _push_items(
            kwargs.items(),
            "fn",
            "item_first" if not positional else "item",
        )
        _push_items(positional, "fn", "pos_item_first", "pos_item")

    def _render_assign(n):
        _emit("%s = " % n["target"])
        value = n["value"]
        stack.append((value, type(value), None))

    def _render_return(n):
        value = n.get("value")
        if value == None:
            _emit("return")
        else:
            _emit("return ")
            stack.append((value, type(value), None))

    def _render_block(n):
        stmts = n["stmts"]
        if not stmts:
            return
        for idx in range(len(stmts) - 1, -1, -1):
            ctx = "stmt_first" if idx == 0 else "stmt"
            stack.append((stmts[idx], type(stmts[idx]), ctx))

    def _render_if(n):
        cond = n["cond"]
        then_stmts = n["then"]
        elifs = n.get("elifs", [])
        else_stmts = n.get("else_")

        if else_stmts != None:
            _push_body(else_stmts)
            stack.append(
                ("\n%selse:" % (tab * state["depth"]), "string", "raw"),
            )

        for i in range(len(elifs) - 1, -1, -1):
            elif_cond, elif_body = elifs[i]
            _push_body(elif_body)
            stack.append((":", "string", "raw"))
            stack.append((elif_cond, type(elif_cond), None))
            stack.append(
                ("\n%selif " % (tab * state["depth"]), "string", "raw"),
            )

        _push_body(then_stmts)

        stack.append((":", "string", "raw"))
        stack.append((cond, type(cond), None))
        _emit("if ")

    def _render_for(n):
        target = n["target"]
        iter_ = n["iter_"]
        body_stmts = n["body"]

        _push_body(body_stmts)
        stack.append((":", "string", "raw"))
        stack.append((iter_, type(iter_), None))
        stack.append((" in ", "string", "raw"))
        stack.append((target, type(target), None))
        _emit("for ")

    def _render_def(n):
        name = n["name"]
        params = n["params"]
        body_stmts = n["body"]

        _push_body(body_stmts)
        params_str = ", ".join([str(p) for p in params])
        stack.append(("):", "string", "raw"))
        if params_str:
            stack.append((params_str, "string", "raw"))
        _emit("def %s(" % name)

    def _render_node(n):
        kind = n[SENTINEL]
        if kind == "expr":
            _emit(n["text"])
        elif kind == "fn":
            _render_fn_call(n)
        elif kind == "assign":
            _render_assign(n)
        elif kind == "return":
            _render_return(n)
        elif kind == "block":
            _render_block(n)
        elif kind == "if":
            _render_if(n)
        elif kind == "for":
            _render_for(n)
        elif kind == "def":
            _render_def(n)
        else:
            fail("starlark.gen: unknown node kind: %s" % kind)

    def _handle_item(current, current_type, context):
        is_first = context in ("item_first", "pos_item_first")
        _emit_sep(is_first)

        if current_type == "dict":
            k, v = current
            k = str(k) if not quote_keys else ("%r" % str(k))
            _emit("%s: " % k)
            stack.append((v, type(v), None))
        elif current_type == "fn" and context in ("item", "item_first"):
            k, v = current
            _emit("%s = " % str(k))
            stack.append((v, type(v), None))
        else:
            stack.append((current, type(current), None))

    for i in range(MAX_ITERATIONS):
        if not stack:
            break

        if i == MAX_ITERATIONS - 1:
            msg = "starlark.gen: iteration limit reached (%d); "
            msg += "value too deeply nested or cyclic: %r"
            fail(msg % (MAX_ITERATIONS, value))

        current, current_type, context = stack.pop()

        if context == "close":
            _emit_close(current)
            continue

        if context in ("item", "item_first", "pos_item", "pos_item_first"):
            _handle_item(current, current_type, context)
            continue

        if context == "raw":
            _emit(current)
            continue

        if context == "indent":
            state["depth"] += 1
            continue

        if context == "dedent":
            state["depth"] -= 1
            continue

        if context == "stmt":
            _emit("\n")
            _emit(tab * state["depth"])
            stack.append((current, type(current), None))
            continue

        if context == "stmt_first":
            _emit(tab * state["depth"])
            stack.append((current, type(current), None))
            continue

        if current_type in ("NoneType", "int", "float", "bool"):
            _emit(str(current))

        elif current_type == "string":
            _emit("%r" % current if quote_strings else escape(current))

        elif current_type in ("list", "tuple", "dict"):
            if current_type == "dict" and SENTINEL in current:
                _render_node(current)
                continue

            _render_container(current, current_type)

        elif current_type == "depset":
            stack.append((fn.fn("depset", current.to_list()), "dict", None))

        elif current_type == "struct":
            kw = {}
            for key in reversed(dir(current)):
                if key != "to_json" and key != "to_proto":
                    kw[key] = getattr(current, key)
            stack.append((fn.fn("struct", **kw), "dict", None))

        else:
            fail("Unsupported type: %s" % current_type)

    return "".join(result)

def _igen(value, **kwargs):
    return _gen(value, indent = True, **kwargs)

def _auto(value, max_width = 80, **kwargs):
    """Render inline if under `max_width`; otherwise indented.

    Args:
        value: The value to render (any type accepted by `gen()`).
        max_width: Maximum single-line width before falling back to multi-line
            rendering. Defaults to 80.
        **kwargs: Forwarded to `gen()` in both branches.

    Returns:
        A Starlark source string, either single-line or indented.
    """
    inline = _gen(value, **kwargs)
    if "\n" not in inline and len(inline) <= max_width:
        return inline
    return _gen(value, indent = True, **kwargs)

gen = struct(
    auto = _auto,
    BRACKETS = BRACKETS,
    escape = escape,
    gen = _gen,
    has_odd_trailing_backslashes = has_odd_trailing_backslashes,
    igen = _igen,
    is_container = is_container,
    MAX_ITERATIONS = MAX_ITERATIONS,
)
