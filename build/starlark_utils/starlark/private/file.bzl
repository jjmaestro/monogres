"""File-level composition helper."""

load("//starlark/private:expr.bzl", "expr")
load("//starlark/private:gen.bzl", "gen")

def file(*parts, header = None):
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
