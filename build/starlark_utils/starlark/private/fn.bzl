"""Function-call node builder and convenience helpers."""

load("//starlark/private:node.bzl", "node")

def _fn(fn_name, *args, **kwargs):
    """Build a raw `fn_name()` function-call node.

    Returns a node dict for `gen()` / `igen()` / `auto()` that renders as
    `fn_name(arg, ..., key = value, ...)`. Positional args become positional in
    the output; keyword args become keyword in the output.

    When indented, a single-container-arg call with no kwargs auto-merges
    brackets: `fn("depset", [1, 2])` renders as `depset([\\n    1,\\n])`.

    Args:
        fn_name: The function name (e.g. `"cfg.new"`).
        *args: Positional arguments for the call.
        **kwargs: Keyword arguments for the call.

    Returns:
        A node dict that `gen()` / `igen()` renders as a function call.
    """
    return node("fn", name = fn_name, args = args, kwargs = kwargs)

def _compact(**kwargs):
    """Filter out `None`-valued keyword arguments.

    Args:
        **kwargs: Keyword arguments to filter.

    Returns:
        A dict with `None` values removed.
    """
    return {k: v for k, v in kwargs.items() if v != None}

def _call(fn_name, *args, **kwargs):
    """Build a function-call node, filtering `None` kwargs.

    Convenience wrapper around `fn()` that drops keyword arguments whose value
    is `None` before constructing the node.

    Args:
        fn_name: The function name.
        *args: Positional arguments for the call.
        **kwargs: Keyword arguments; `None` values are omitted.

    Returns:
        A node dict that `gen()` / `igen()` renders as a function call.
    """
    return _fn(fn_name, *args, **_compact(**kwargs))

fn = struct(
    call = _call,
    compact = _compact,
    fn = _fn,
)
