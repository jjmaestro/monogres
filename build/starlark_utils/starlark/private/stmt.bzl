"""Statement-level node builders."""

load("//starlark/private:node.bzl", "node")

def _assign(target, value):
    """Build an assignment statement `target = value`.

    Args:
        target: Left-hand side identifier.
        value: Right-hand side expression or value.

    Returns:
        A node dict for `gen()`.
    """
    return node("assign", target = target, value = value)

def _return_(value = None):
    """Build a `return` statement.

    Args:
        value: Optional return value; omit or pass `None` for a bare `return`.

    Returns:
        A node dict for `gen()`.
    """
    return node("return", value = value)

def _block(*stmts):
    """Group statements into a single block.

    Args:
        *stmts: Statements to group.

    Returns:
        A node dict for `gen()`.
    """
    return node("block", stmts = stmts)

def _make_post_then(cond, then, elifs):
    """Build the post-then continuation for `if_()`.

    Args:
        cond: The original `if` condition.
        then: Body of the `then` branch.
        elifs: Accumulated `elif` branches.

    Returns:
        A struct with `elif_()`, `else_()`, and `done`.
    """

    def if_(**kwargs):
        return node("if", cond = cond, then = then, elifs = elifs, **kwargs)

    def _elif(elif_cond):
        def _elif_then(*stmts):
            return _make_post_then(
                cond,
                then,
                elifs + [(elif_cond, stmts)],
            )

        return struct(then = _elif_then)

    def _else(*stmts):
        return if_(else_ = stmts)

    return struct(elif_ = _elif, else_ = _else, done = if_())

def _if_(cond):
    """Build an `if` statement with fluent API.

    Usage::

        if_(c).then(...).elif_(c2).then(...).else_(...)

    Use `.done` instead of `.else_(...)` to omit the else branch.

    Args:
        cond: The condition expression.

    Returns:
        A struct with a `then()` method.
    """

    def _then(*stmts):
        return _make_post_then(cond, stmts, [])

    return struct(then = _then)

def _for_(target, iter_):
    """Build a `for` loop with fluent API.

    Usage: `for_(target, iter_).do_(...)`.

    Args:
        target: Loop variable.
        iter_: Iterable expression.

    Returns:
        A struct with a `do_()` method.
    """

    def _do(*stmts):
        return node("for", target = target, iter_ = iter_, body = stmts)

    return struct(do_ = _do)

def _def_(name, *params):
    """Build a `def` statement with fluent API.

    Usage: `def_(name, *params).body_(...)`.

    Args:
        name: Function name.
        *params: Parameter names.

    Returns:
        A struct with a `body_()` method.
    """

    def _body(*stmts):
        return node("def", name = name, params = params, body = stmts)

    return struct(body_ = _body)

stmt = struct(
    assign = _assign,
    block = _block,
    def_ = _def_,
    for_ = _for_,
    if_ = _if_,
    return_ = _return_,
)
