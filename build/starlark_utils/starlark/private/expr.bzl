"""Expression-level node builders."""

load("//starlark/private:gen.bzl", "gen")
load("//starlark/private:node.bzl", "node")

def _expr(text):
    """Tag a string as a verbatim expression.

    Use when you want a value to render as unquoted Starlark source text —
    anything from a bare identifier (`"OPTIONS"`) to an arbitrary expression
    (`"sorted(CFGS.keys())"`, `"foo.bar[0]"`) — without toggling `quote_strings
    = False` globally and manually pre-quoting every other string.

    Args:
        text: Expression text to emit verbatim.

    Returns:
        A node dict that `gen()` / `igen()` / `assignments()` render as the bare
        text.
    """
    return node("expr", text = text)

def _common_prefix(lines):
    """The indentation shared by every non-blank line, `""` if they share none."""
    indents = [
        line[:len(line) - len(line.lstrip())]
        for line in lines
        if line.strip()
    ]

    if not indents:
        return ""

    # The shortest indentation is the longest prefix the others can share
    prefix = indents[0][:min([len(indent) for indent in indents])]

    for indent in indents:
        if not indent.startswith(prefix):
            # Mixed indentation (e.g. tabs and spaces): no common prefix
            return ""

    return prefix

def _comment(text, remove_prefix = True):
    """Build a `# comment` block as a node value.

    Multi-line input produces one `# ` prefixed line per input line; blank lines
    become `#` with no trailing space.

    Args:
        text: Comment body (may contain newlines).
        remove_prefix: If `True` (the default), remove the indentation that
            every non-blank line shares, along with the blank lines around the
            block, so that a multi-line literal can be written aligned with the
            code that builds it, the way a `doc` string is, and still render
            flush against the `#`. Relative indentation is kept. Set to `False`
            for a comment whose own indentation is meaningful (a diagram, a code
            sample).

    Returns:
        A node dict that renders as `# ...` lines.
    """
    lines = text.split("\n")

    if remove_prefix:
        # Drop the blank lines around the block: with a `"""` literal those are
        # the newline before the closing quotes and the indentation before them
        body = [i for i, line in enumerate(lines) if line.strip()]
        lines = lines[body[0]:body[-1] + 1] if body else []

        prefix = _common_prefix(lines)
        lines = [line.removeprefix(prefix).rstrip() for line in lines]

    return _expr("\n".join(["# " + line if line else "#" for line in lines]))

def _tstr(text):
    """Build a triple-quoted string literal.

    Prefers double-quote form by default. When `text` contains triple
    double-quotes, switches to single-quote form for readability — unless `text`
    also contains triple single-quotes, in which case it falls back to the
    escaped double-quote form.

    Args:
        text: Content to wrap.

    Returns:
        A node dict that renders as the literal.
    """
    if '"""' in text and "'''" not in text:
        escaped = text.replace("\\", "\\\\").replace("'", "\\'")
        return _expr("'''%s'''" % escaped)

    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return _expr('"""%s"""' % escaped)

def _rstr(text, _fail = fail):
    """Build a raw string literal `r"text"`.

    Args:
        text: Raw content to wrap.
        _fail: Injected for testability; do not set.

    Returns:
        A node dict that renders as the raw literal.
    """
    if "\"" in text:
        return _fail(
            'rstr: text contains a double-quote; use rtstr (if no """) or tstr',
        )

    if gen.has_odd_trailing_backslashes(text):
        return _fail("rstr: raw literals cannot end with an odd number of backslashes; use tstr instead")

    if "\n" in text:
        return _fail(
            "rstr: raw single-line literals cannot contain newlines; use rtstr",
        )

    return _expr('r"%s"' % text)

def _rtstr(text, _fail = fail):
    """Build a raw triple-quoted string literal.

    Args:
        text: Raw content to wrap.
        _fail: Injected for testability; do not set.

    Returns:
        A node dict that renders as the literal.
    """
    if '"""' in text:
        return _fail("rtstr: text contains a triple-quote; use tstr instead")

    if text.endswith("\""):
        return _fail("rtstr: raw triple literals cannot end with a double-quote; use tstr")

    if gen.has_odd_trailing_backslashes(text):
        return _fail("rtstr: raw literals cannot end with an odd number of backslashes; use tstr instead")

    return _expr('r"""%s"""' % text)

def _binop(op, *operands, _fail = fail):
    """Build a binary operation expression.

    Renders as `op1 <op> op2 <op> ...`.

    Args:
        op: The operator (e.g. `"+"`, `"and"`).
        *operands: At least two operands, each any type accepted by `gen()`.
        _fail: Injected for testability; do not set.

    Returns:
        A node dict that renders as the operation.
    """
    if len(operands) < 2:
        return _fail(
            "binop requires at least 2 operands, got %d" % len(operands),
        )
    rendered = [gen.gen(o) for o in operands]
    return _expr((" %s " % op).join(rendered))

def _ternary(cond, then, else_):
    """Build a ternary `then if cond else else_`.

    Args:
        cond: The condition expression.
        then: Value when `cond` is truthy.
        else_: Value otherwise.

    Returns:
        A node dict that renders as the conditional.
    """
    return _expr(
        "%s if %s else %s" % (gen.gen(then), gen.gen(cond), gen.gen(else_)),
    )

def _comprehension(kind, expr_, target, iter_, cond = None):
    result = "%s%s for %s in %s" % (
        gen.BRACKETS["open"][kind],
        gen.gen(expr_),
        gen.gen(target),
        gen.gen(iter_),
    )

    if cond != None:
        result += " if %s" % gen.gen(cond)

    result += gen.BRACKETS["close"][kind]

    return _expr(result)

def _listcomp(expr_, target, iter_, cond = None):
    """Build a list comprehension.

    Renders as `[expr for target in iter_[ if cond]]`.

    Args:
        expr_: Result expression.
        target: Loop target.
        iter_: Iterable expression.
        cond: Optional filter expression.

    Returns:
        A node dict that renders as the comprehension.
    """
    return _comprehension("list", expr_, target, iter_, cond)

def _dictcomp(key, value, target, iter_, cond = None):
    """Build a dict comprehension.

    Renders as `{key: value for target in iter_[ if cond]}`.

    Args:
        key: Key expression.
        value: Value expression.
        target: Loop target.
        iter_: Iterable expression.
        cond: Optional filter expression.

    Returns:
        A node dict that renders as the comprehension.
    """
    expr_ = _expr("%s: %s" % (gen.gen(key), gen.gen(value)))
    return _comprehension("dict", expr_, target, iter_, cond)

expr = struct(
    binop = _binop,
    comment = _comment,
    dictcomp = _dictcomp,
    expr = _expr,
    listcomp = _listcomp,
    rstr = _rstr,
    rtstr = _rtstr,
    ternary = _ternary,
    tstr = _tstr,
)
