<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Starlark source code generation.

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
- File composition: `file()` joins parts with blank lines.
- BUILD helpers: `package()`, `alias()`, `exports_files()`,
  `bzl_library()`.

<a id="starlark.alias"></a>

## starlark.alias

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.alias(<a href="#starlark.alias-name">name</a>, <a href="#starlark.alias-actual">actual</a>, <a href="#starlark.alias-visibility">visibility</a>)
</pre>

Build an `alias()` call, auto-formatted.

See [alias](https://bazel.build/reference/be/general#alias).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.alias-name"></a>name |  Target name.   |  none |
| <a id="starlark.alias-actual"></a>actual |  The actual target.   |  none |
| <a id="starlark.alias-visibility"></a>visibility |  Optional visibility.   |  `None` |

**RETURNS**

A pre-rendered Starlark string.


<a id="starlark.assign"></a>

## starlark.assign

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.assign(<a href="#starlark.assign-target">target</a>, <a href="#starlark.assign-value">value</a>)
</pre>

Build an assignment statement `target = value`.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.assign-target"></a>target |  Left-hand side identifier.   |  none |
| <a id="starlark.assign-value"></a>value |  Right-hand side expression or value.   |  none |

**RETURNS**

A node dict for `gen()`.


<a id="starlark.auto"></a>

## starlark.auto

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.auto(<a href="#starlark.auto-value">value</a>, <a href="#starlark.auto-max_width">max_width</a>, <a href="#starlark.auto-kwargs">**kwargs</a>)
</pre>

Render inline if under `max_width`; otherwise indented.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.auto-value"></a>value |  The value to render (any type accepted by `gen()`).   |  none |
| <a id="starlark.auto-max_width"></a>max_width |  Maximum single-line width before falling back to multi-line rendering. Defaults to 80.   |  `80` |
| <a id="starlark.auto-kwargs"></a>kwargs |  Forwarded to `gen()` in both branches.   |  none |

**RETURNS**

A Starlark source string, either single-line or indented.


<a id="starlark.binop"></a>

## starlark.binop

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.binop(<a href="#starlark.binop-op">op</a>, <a href="#starlark.binop-operands">*operands</a>, <a href="#starlark.binop-_fail">_fail</a>)
</pre>

Build a binary operation expression.

Renders as `op1 <op> op2 <op> ...`.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.binop-op"></a>op |  The operator (e.g. `"+"`, `"and"`).   |  none |
| <a id="starlark.binop-_fail"></a>_fail |  Injected for testability; do not set.   |  `<built-in function fail>` |
| <a id="starlark.binop-operands"></a>operands |  At least two operands, each any type accepted by `gen()`.   |  none |

**RETURNS**

A node dict that renders as the operation.


<a id="starlark.block"></a>

## starlark.block

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.block(<a href="#starlark.block-stmts">*stmts</a>)
</pre>

Group statements into a single block.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.block-stmts"></a>stmts |  Statements to group.   |  none |

**RETURNS**

A node dict for `gen()`.


<a id="starlark.bzl_library"></a>

## starlark.bzl_library

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.bzl_library(<a href="#starlark.bzl_library-name">name</a>, <a href="#starlark.bzl_library-srcs">srcs</a>, <a href="#starlark.bzl_library-deps">deps</a>, <a href="#starlark.bzl_library-visibility">visibility</a>)
</pre>

Build a `bzl_library()` call, indented.

See [bzl_library](https://github.com/bazelbuild/bazel-skylib/blob/main/docs/bzl_library.md).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.bzl_library-name"></a>name |  Target name.   |  none |
| <a id="starlark.bzl_library-srcs"></a>srcs |  Source `.bzl` files.   |  `None` |
| <a id="starlark.bzl_library-deps"></a>deps |  Dependencies.   |  `None` |
| <a id="starlark.bzl_library-visibility"></a>visibility |  Optional visibility.   |  `None` |

**RETURNS**

A pre-rendered indented Starlark string.


<a id="starlark.comment"></a>

## starlark.comment

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.comment(<a href="#starlark.comment-text">text</a>, <a href="#starlark.comment-remove_prefix">remove_prefix</a>)
</pre>

Build a `# comment` block as a node value.

Multi-line input produces one `# ` prefixed line per input line; blank lines
become `#` with no trailing space.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.comment-text"></a>text |  Comment body (may contain newlines).   |  none |
| <a id="starlark.comment-remove_prefix"></a>remove_prefix |  If `True` (the default), remove the indentation that every non-blank line shares, along with the blank lines around the block, so that a multi-line literal can be written aligned with the code that builds it, the way a `doc` string is, and still render flush against the `#`. Relative indentation is kept. Set to `False` for a comment whose own indentation is meaningful (a diagram, a code sample).   |  `True` |

**RETURNS**

A node dict that renders as `# ...` lines.


<a id="starlark.def_"></a>

## starlark.def_

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.def_(<a href="#starlark.def_-name">name</a>, <a href="#starlark.def_-params">*params</a>)
</pre>

Build a `def` statement with fluent API.

Usage: `def_(name, *params).body_(...)`.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.def_-name"></a>name |  Function name.   |  none |
| <a id="starlark.def_-params"></a>params |  Parameter names.   |  none |

**RETURNS**

A struct with a `body_()` method.


<a id="starlark.dictcomp"></a>

## starlark.dictcomp

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.dictcomp(<a href="#starlark.dictcomp-key">key</a>, <a href="#starlark.dictcomp-value">value</a>, <a href="#starlark.dictcomp-target">target</a>, <a href="#starlark.dictcomp-iter_">iter_</a>, <a href="#starlark.dictcomp-cond">cond</a>)
</pre>

Build a dict comprehension.

Renders as `{key: value for target in iter_[ if cond]}`.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.dictcomp-key"></a>key |  Key expression.   |  none |
| <a id="starlark.dictcomp-value"></a>value |  Value expression.   |  none |
| <a id="starlark.dictcomp-target"></a>target |  Loop target.   |  none |
| <a id="starlark.dictcomp-iter_"></a>iter_ |  Iterable expression.   |  none |
| <a id="starlark.dictcomp-cond"></a>cond |  Optional filter expression.   |  `None` |

**RETURNS**

A node dict that renders as the comprehension.


<a id="starlark.docstring"></a>

## starlark.docstring

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.docstring(<a href="#starlark.docstring-text">text</a>)
</pre>

Build a triple-quoted string literal.

Prefers double-quote form by default. When `text` contains triple
double-quotes, switches to single-quote form for readability — unless `text`
also contains triple single-quotes, in which case it falls back to the
escaped double-quote form.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.docstring-text"></a>text |  Content to wrap.   |  none |

**RETURNS**

A node dict that renders as the literal.


<a id="starlark.exports_files"></a>

## starlark.exports_files

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.exports_files(<a href="#starlark.exports_files-srcs">srcs</a>, <a href="#starlark.exports_files-visibility">visibility</a>, <a href="#starlark.exports_files-licenses">licenses</a>)
</pre>

Build an `exports_files()` call, auto-formatted.

See [exports_files](https://bazel.build/reference/be/functions#exports_files).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.exports_files-srcs"></a>srcs |  Files to export.   |  none |
| <a id="starlark.exports_files-visibility"></a>visibility |  Optional visibility.   |  `None` |
| <a id="starlark.exports_files-licenses"></a>licenses |  Optional licenses.   |  `None` |

**RETURNS**

A pre-rendered Starlark string.


<a id="starlark.expr"></a>

## starlark.expr

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.expr(<a href="#starlark.expr-text">text</a>)
</pre>

Tag a string as a verbatim expression.

Use when you want a value to render as unquoted Starlark source text —
anything from a bare identifier (`"OPTIONS"`) to an arbitrary expression
(`"sorted(CFGS.keys())"`, `"foo.bar[0]"`) — without toggling `quote_strings
= False` globally and manually pre-quoting every other string.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.expr-text"></a>text |  Expression text to emit verbatim.   |  none |

**RETURNS**

A node dict that `gen()` / `igen()` / `auto()` render as the bare text.


<a id="starlark.file"></a>

## starlark.file

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.file(<a href="#starlark.file-parts">*parts</a>, <a href="#starlark.file-header">header</a>)
</pre>

Compose a generated Starlark file.

Joins an optional header and parts with blank lines, terminated by a single
newline.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.file-header"></a>header |  Optional top-of-file header. May be a plain string (auto-wrapped via `tstr()`) or a pre-built node value.   |  `None` |
| <a id="starlark.file-parts"></a>parts |  Top-level statements. Each may be a pre-rendered string or a node value. Falsy parts (`""`, `None`, `[]`, etc.) are filtered out automatically.   |  none |

**RETURNS**

The composed file content with trailing newline.


<a id="starlark.fn"></a>

## starlark.fn

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.fn(<a href="#starlark.fn-fn_name">fn_name</a>, <a href="#starlark.fn-args">*args</a>, <a href="#starlark.fn-kwargs">**kwargs</a>)
</pre>

Build a raw `fn_name()` function-call node.

Returns a node dict for `gen()` / `igen()` / `auto()` that renders as
`fn_name(arg, ..., key = value, ...)`. Positional args become positional in
the output; keyword args become keyword in the output.

When indented, a single-container-arg call with no kwargs auto-merges
brackets: `fn("depset", [1, 2])` renders as `depset([\n    1,\n])`.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.fn-fn_name"></a>fn_name |  The function name (e.g. `"cfg.new"`).   |  none |
| <a id="starlark.fn-args"></a>args |  Positional arguments for the call.   |  none |
| <a id="starlark.fn-kwargs"></a>kwargs |  Keyword arguments for the call.   |  none |

**RETURNS**

A node dict that `gen()` / `igen()` renders as a function call.


<a id="starlark.for_"></a>

## starlark.for_

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.for_(<a href="#starlark.for_-target">target</a>, <a href="#starlark.for_-iter_">iter_</a>)
</pre>

Build a `for` loop with fluent API.

Usage: `for_(target, iter_).do_(...)`.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.for_-target"></a>target |  Loop variable.   |  none |
| <a id="starlark.for_-iter_"></a>iter_ |  Iterable expression.   |  none |

**RETURNS**

A struct with a `do_()` method.


<a id="starlark.gen"></a>

## starlark.gen

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.gen(<a href="#starlark.gen-value">value</a>, <a href="#starlark.gen-indent">indent</a>, <a href="#starlark.gen-indent_count">indent_count</a>, <a href="#starlark.gen-indent_size">indent_size</a>, <a href="#starlark.gen-quote_strings">quote_strings</a>, <a href="#starlark.gen-quote_keys">quote_keys</a>)
</pre>

Generate a Starlark source string representation of a value.

Supports nested data structures, including `list`, `tuple`, `dict`,
`depset`, and `struct`, and applies quoting/formatting as configured.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.gen-value"></a>value |  The value to render. Can be any Starlark-compatible type.   |  none |
| <a id="starlark.gen-indent"></a>indent |  If `True`, pretty-print with indentation.   |  `False` |
| <a id="starlark.gen-indent_count"></a>indent_count |  Base indentation level.   |  `0` |
| <a id="starlark.gen-indent_size"></a>indent_size |  Number of spaces per indent level.   |  `4` |
| <a id="starlark.gen-quote_strings"></a>quote_strings |  Whether to quote `string` values.   |  `True` |
| <a id="starlark.gen-quote_keys"></a>quote_keys |  Whether to quote `dict` keys.   |  `True` |

**RETURNS**

A Starlark-compatible source string.


<a id="starlark.glob"></a>

## starlark.glob

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.glob(<a href="#starlark.glob-include">include</a>, <a href="#starlark.glob-exclude">exclude</a>, <a href="#starlark.glob-exclude_directories">exclude_directories</a>, <a href="#starlark.glob-allow_empty">allow_empty</a>)
</pre>

Build a `glob()` call.

See [glob](https://bazel.build/reference/be/functions#glob).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.glob-include"></a>include |  Patterns to include.   |  none |
| <a id="starlark.glob-exclude"></a>exclude |  Patterns to exclude.   |  `None` |
| <a id="starlark.glob-exclude_directories"></a>exclude_directories |  Whether to exclude dirs.   |  `None` |
| <a id="starlark.glob-allow_empty"></a>allow_empty |  Whether an empty result is OK.   |  `None` |

**RETURNS**

A node dict for `gen()` / `igen()` / `auto()`.


<a id="starlark.if_"></a>

## starlark.if_

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.if_(<a href="#starlark.if_-cond">cond</a>)
</pre>

Build an `if` statement with fluent API.

Usage::

    if_(c).then(...).elif_(c2).then(...).else_(...)

Use `.done` instead of `.else_(...)` to omit the else branch.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.if_-cond"></a>cond |  The condition expression.   |  none |

**RETURNS**

A struct with a `then()` method.


<a id="starlark.igen"></a>

## starlark.igen

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.igen(<a href="#starlark.igen-value">value</a>, <a href="#starlark.igen-kwargs">**kwargs</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.igen-value"></a>value |  <p align="center"> - </p>   |  none |
| <a id="starlark.igen-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


<a id="starlark.listcomp"></a>

## starlark.listcomp

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.listcomp(<a href="#starlark.listcomp-expr_">expr_</a>, <a href="#starlark.listcomp-target">target</a>, <a href="#starlark.listcomp-iter_">iter_</a>, <a href="#starlark.listcomp-cond">cond</a>)
</pre>

Build a list comprehension.

Renders as `[expr for target in iter_[ if cond]]`.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.listcomp-expr_"></a>expr_ |  Result expression.   |  none |
| <a id="starlark.listcomp-target"></a>target |  Loop target.   |  none |
| <a id="starlark.listcomp-iter_"></a>iter_ |  Iterable expression.   |  none |
| <a id="starlark.listcomp-cond"></a>cond |  Optional filter expression.   |  `None` |

**RETURNS**

A node dict that renders as the comprehension.


<a id="starlark.load_"></a>

## starlark.load_

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.load_(<a href="#starlark.load_-args">*args</a>, <a href="#starlark.load_-kwargs">**kwargs</a>)
</pre>

Build a Starlark `load()` statement.

See [load](https://bazel.build/concepts/build-files#load).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.load_-args"></a>args |  Positional arguments — first is the file label, followed by symbols to import.   |  none |
| <a id="starlark.load_-kwargs"></a>kwargs |  Keyword arguments for symbol renaming.   |  none |

**RETURNS**

A node dict for `gen()` / `igen()` / `auto()`.


<a id="starlark.package"></a>

## starlark.package

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.package(<a href="#starlark.package-default_applicable_licenses">default_applicable_licenses</a>, <a href="#starlark.package-default_deprecation">default_deprecation</a>, <a href="#starlark.package-default_package_metadata">default_package_metadata</a>,
                 <a href="#starlark.package-default_testonly">default_testonly</a>, <a href="#starlark.package-default_visibility">default_visibility</a>, <a href="#starlark.package-features">features</a>)
</pre>

Build a `package()` call, auto-formatted.

See [package](https://bazel.build/reference/be/functions#package).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.package-default_applicable_licenses"></a>default_applicable_licenses |  Default licenses.   |  `None` |
| <a id="starlark.package-default_deprecation"></a>default_deprecation |  Default deprecation notice.   |  `None` |
| <a id="starlark.package-default_package_metadata"></a>default_package_metadata |  Default metadata.   |  `None` |
| <a id="starlark.package-default_testonly"></a>default_testonly |  Default testonly flag.   |  `None` |
| <a id="starlark.package-default_visibility"></a>default_visibility |  Default visibility.   |  `None` |
| <a id="starlark.package-features"></a>features |  Package features.   |  `None` |

**RETURNS**

A pre-rendered Starlark string.


<a id="starlark.ref"></a>

## starlark.ref

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.ref(<a href="#starlark.ref-text">text</a>)
</pre>

Tag a string as a verbatim expression.

Use when you want a value to render as unquoted Starlark source text —
anything from a bare identifier (`"OPTIONS"`) to an arbitrary expression
(`"sorted(CFGS.keys())"`, `"foo.bar[0]"`) — without toggling `quote_strings
= False` globally and manually pre-quoting every other string.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.ref-text"></a>text |  Expression text to emit verbatim.   |  none |

**RETURNS**

A node dict that `gen()` / `igen()` / `auto()` render as the bare text.


<a id="starlark.return_"></a>

## starlark.return_

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.return_(<a href="#starlark.return_-value">value</a>)
</pre>

Build a `return` statement.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.return_-value"></a>value |  Optional return value; omit or pass `None` for a bare `return`.   |  `None` |

**RETURNS**

A node dict for `gen()`.


<a id="starlark.rstr"></a>

## starlark.rstr

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.rstr(<a href="#starlark.rstr-text">text</a>, <a href="#starlark.rstr-_fail">_fail</a>)
</pre>

Build a raw string literal `r"text"`.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.rstr-text"></a>text |  Raw content to wrap.   |  none |
| <a id="starlark.rstr-_fail"></a>_fail |  Injected for testability; do not set.   |  `<built-in function fail>` |

**RETURNS**

A node dict that renders as the raw literal.


<a id="starlark.rtstr"></a>

## starlark.rtstr

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.rtstr(<a href="#starlark.rtstr-text">text</a>, <a href="#starlark.rtstr-_fail">_fail</a>)
</pre>

Build a raw triple-quoted string literal.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.rtstr-text"></a>text |  Raw content to wrap.   |  none |
| <a id="starlark.rtstr-_fail"></a>_fail |  Injected for testability; do not set.   |  `<built-in function fail>` |

**RETURNS**

A node dict that renders as the literal.


<a id="starlark.select"></a>

## starlark.select

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.select(<a href="#starlark.select-conditions">conditions</a>, <a href="#starlark.select-no_match_error">no_match_error</a>)
</pre>

Build a `select()` call.

See [select](https://bazel.build/reference/be/functions#select).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.select-conditions"></a>conditions |  Condition-to-value mapping.   |  none |
| <a id="starlark.select-no_match_error"></a>no_match_error |  Optional error message.   |  `None` |

**RETURNS**

A node dict for `gen()` / `igen()` / `auto()`.


<a id="starlark.ternary"></a>

## starlark.ternary

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.ternary(<a href="#starlark.ternary-cond">cond</a>, <a href="#starlark.ternary-then">then</a>, <a href="#starlark.ternary-else_">else_</a>)
</pre>

Build a ternary `then if cond else else_`.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.ternary-cond"></a>cond |  The condition expression.   |  none |
| <a id="starlark.ternary-then"></a>then |  Value when `cond` is truthy.   |  none |
| <a id="starlark.ternary-else_"></a>else_ |  Value otherwise.   |  none |

**RETURNS**

A node dict that renders as the conditional.


<a id="starlark.tstr"></a>

## starlark.tstr

<pre>
load("@starlark_utils//starlark:starlark.bzl", "starlark")

starlark.tstr(<a href="#starlark.tstr-text">text</a>)
</pre>

Build a triple-quoted string literal.

Prefers double-quote form by default. When `text` contains triple
double-quotes, switches to single-quote form for readability — unless `text`
also contains triple single-quotes, in which case it falls back to the
escaped double-quote form.


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="starlark.tstr-text"></a>text |  Content to wrap.   |  none |

**RETURNS**

A node dict that renders as the literal.


