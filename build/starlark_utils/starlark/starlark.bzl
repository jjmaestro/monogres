"""Starlark source code generation.

This module provides functions for converting native Starlark-compatible values
(e.g., `dict`, `list`, `struct`, `depset`) into valid Starlark source code,
either as compact strings or with readable indentation.

It's useful for code generation tasks such as emitting `.bzl` files or `BUILD`
snippets programmatically.

The `starlark` module API:
- Node builders: `fn()`, `load_()`, `expr()`/`ref()`, `comment()`,
  `tstr()`/`docstring()`, `rstr()`, `rtstr()`, `glob()`, `select()`, `binop()`,
  `listcomp()`, `dictcomp()`, `ternary()`.
- Statement builders: `assign()`, `return_()`, `block()`, `if_()`,
  `for_()`, `def_()`.
- Renderers: `gen()` (single-line), `igen()` (indented), `auto()`
  (inline if it fits, else indented).
- Helpers: `assignments(assignments, ...)` generates `key = value`
  assignments.
- File composition: `file()` joins parts with blank lines.
- BUILD helpers: `package()`, `alias()`, `exports_files()`,
  `bzl_library()`.
"""

load("//starlark/private:bazel.bzl", "bazel")
load("//starlark/private:expr.bzl", "expr")
load("//starlark/private:fn.bzl", "fn")
load("//starlark/private:gen.bzl", "gen")
load("//starlark/private:helpers.bzl", "helpers")
load("//starlark/private:stmt.bzl", "stmt")

starlark = struct(
    alias = bazel.alias,
    assign = stmt.assign,
    assignments = helpers.assignments,
    auto = gen.auto,
    binop = expr.binop,
    block = stmt.block,
    bzl_library = bazel.bzl_library,
    comment = expr.comment,
    def_ = stmt.def_,
    dictcomp = expr.dictcomp,
    docstring = expr.tstr,
    exports_files = bazel.exports_files,
    expr = expr.expr,
    file = helpers.file,
    fn = fn.fn,
    for_ = stmt.for_,
    gen = gen.gen,
    glob = bazel.glob,
    if_ = stmt.if_,
    igen = gen.igen,
    listcomp = expr.listcomp,
    load_ = bazel.load_,
    package = bazel.package,
    ref = expr.expr,
    return_ = stmt.return_,
    rstr = expr.rstr,
    rtstr = expr.rtstr,
    select = bazel.select,
    ternary = expr.ternary,
    tstr = expr.tstr,
    __test__ = struct(
        _escape = gen.escape,
    ),
)
