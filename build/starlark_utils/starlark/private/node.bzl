"""IR node foundation: sentinel and constructor."""

SENTINEL = "__starlark_node__"

def node(kind, **fields):
    d = {SENTINEL: kind}
    d.update(fields)
    return d
