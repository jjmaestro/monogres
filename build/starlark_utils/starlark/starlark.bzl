"""
# Starlark source code generation.

This module provides functions for converting native Starlark-compatible values
(e.g., `dict`, `list`, `struct`, `depset`) into valid Starlark source code,
either as compact strings or with readable indentation.

It's useful for code generation tasks such as emitting `.bzl` files or `BUILD`
snippets programmatically.

The `starlark` module has the following functions:
- `gen(value, ...)`: Generate compact single-line Starlark code.
- `igen(value, ...)`: Generate indented multi-line Starlark string.
- `assignments(assignments, ...)`: Generate `key = value` assignments.
- `load_(label, *args, **kwargs)`: Generate a Starlark `load()` statement.
"""

load("//starlark/private:gen.bzl", _escape = "escape", _gen = "gen")
load("//starlark/private:helpers.bzl", _assignments = "assignments", _load = "load_")

starlark = struct(
    gen = _gen,
    igen = lambda value, **kwargs: _gen(value, indent = True, **kwargs),
    assignments = _assignments,
    load_ = _load,
    __test__ = struct(
        _escape = _escape,
    ),
)
