"""File-level helpers: assignments and file composition."""

load("//starlark/private:expr.bzl", "expr")
load("//starlark/private:gen.bzl", "gen")
load("//starlark/private:node.bzl", "SENTINEL")

def _assignments(
        assignments,
        inline = True,
        quote_values = True,
        indent_count = 0,
        indent_size = 4):
    """Generate Starlark `key = value` assignment strings.

    Args:
        assignments: A `dict`, `list` of 2-tuples, or `tuple` of 2-tuples.
        inline: If `True`, return a single-line comma-separated string. If
            `False`, return a newline-separated block.
        quote_values: If `True`, quote string values.
        indent_count: Base indentation level (only when `inline` is `False`).
        indent_size: Spaces per indent level.

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

    def render_value(v):
        if type(v) == "dict" and SENTINEL in v:
            return gen.gen(v)
        return ("%r" if quote_values else "%s") % v

    return sep.join([
        "%s%s = %s" % (prefix, k, render_value(v))
        for k, v in items
    ])

def _file(*parts, header = None):
    """Compose a generated Starlark file.

    Joins an optional header and parts with blank lines, terminated by a single
    newline.

    Args:
        *parts: Top-level statements. Each may be a pre-rendered string or a
            node value. Falsy parts (`""`, `None`, `[]`, etc.) are filtered out
            automatically.
        header: Optional top-of-file header. May be a plain string (auto-wrapped
            via `tstr()`) or a pre-built node value.

    Returns:
        The composed file content with trailing newline.
    """

    def _render(p):
        return p if type(p) == "string" else gen.auto(p)

    items = []

    if header:
        h = header if type(header) != "string" else expr.tstr(header)
        items.append(_render(h))

    items += [_render(p) for p in parts if p]

    return "\n\n".join(items) + "\n"

helpers = struct(
    assignments = _assignments,
    file = _file,
)
