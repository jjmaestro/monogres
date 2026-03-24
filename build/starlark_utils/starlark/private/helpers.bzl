"""Higher-level Starlark formatting helpers."""

def assignments(
        assignments,
        inline = True,
        quote_values = True,
        indent_count = 0,
        indent_size = 4):
    """Generates a Starlark assignment strings from a `dict` or `list` of key-value pairs.

    Args:
        assignments: A `dict`, `list` of 2-tuples, or `tuple` of 2-tuples.
        inline (bool): If `True`, return a single-line comma-separated list. If
            `False`, return a newline-separated block.
        quote_values (bool): If `True`, quote string values.
        indent_count (int): Base indentation level (only used when `inline` is
            `False`).
        indent_size (int): Number of spaces per indent level.

    Returns:
        A string of the form `key1 = value1, key2 = value2, ...`.
    """
    prefix = "" if inline else " " * (indent_size * indent_count)
    sep = ", " if inline else "\n"

    if type(assignments) == "dict":
        items = assignments.items()
    elif type(assignments) in ("list", "tuple"):
        items = assignments
    else:
        fail("Invalid assignments type: %s" % type(assignments))

    return sep.join([
        ("%s%s = %r" if quote_values else "%s%s = %s") % (prefix, k, v)
        for k, v in items
    ])

def load_(*args, **kwargs):
    """
    Generates a Starlark `load()` statement.

    Args:
        *args: Positional arguments — first must be the label of the file,
            followed by symbols to import.
        **kwargs: Keyword arguments for symbol renaming (e.g., `alias =
            "actual"`).

    Returns:
        A valid Starlark `load()` statement as a string.
    """
    load_ = [", ".join(["%r" % arg for arg in args])]

    kwargs_ = assignments(kwargs)
    if kwargs_:
        load_.append(kwargs_)

    return "load(%s)" % ", ".join(load_)
