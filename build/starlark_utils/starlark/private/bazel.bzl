"""Bazel convenience wrappers for common function calls."""

load("//starlark/private:fn.bzl", "fn")
load("//starlark/private:gen.bzl", "gen")

def _load_(*args, **kwargs):
    """Build a Starlark `load()` statement.

    See [load](https://bazel.build/concepts/build-files#load).

    Args:
        *args: Positional arguments — first is the file label, followed by
            symbols to import.
        **kwargs: Keyword arguments for symbol renaming.

    Returns:
        A node dict for `gen()` / `igen()` / `auto()`.
    """
    return fn.fn("load", *args, **kwargs)

def _glob(include, exclude = None, exclude_directories = None, allow_empty = None):
    """Build a `glob()` call.

    See [glob](https://bazel.build/reference/be/functions#glob).

    Args:
        include: Patterns to include.
        exclude: Patterns to exclude.
        exclude_directories: Whether to exclude dirs.
        allow_empty: Whether an empty result is OK.

    Returns:
        A node dict for `gen()` / `igen()` / `auto()`.
    """
    return fn.call(
        "glob",
        include,
        exclude = exclude,
        exclude_directories = exclude_directories,
        allow_empty = allow_empty,
    )

def _select(conditions, no_match_error = None):
    """Build a `select()` call.

    See [select](https://bazel.build/reference/be/functions#select).

    Args:
        conditions: Condition-to-value mapping.
        no_match_error: Optional error message.

    Returns:
        A node dict for `gen()` / `igen()` / `auto()`.
    """
    return fn.call(
        "select",
        conditions,
        no_match_error = no_match_error,
    )

def _package(
        default_applicable_licenses = None,
        default_deprecation = None,
        default_package_metadata = None,
        default_testonly = None,
        default_visibility = None,
        features = None):
    """Build a `package()` call, auto-formatted.

    See [package](https://bazel.build/reference/be/functions#package).

    Args:
        default_applicable_licenses: Default licenses.
        default_deprecation: Default deprecation notice.
        default_package_metadata: Default metadata.
        default_testonly: Default testonly flag.
        default_visibility: Default visibility.
        features: Package features.

    Returns:
        A pre-rendered Starlark string.
    """
    return gen.auto(fn.call(
        "package",
        default_applicable_licenses = default_applicable_licenses,
        default_deprecation = default_deprecation,
        default_package_metadata = default_package_metadata,
        default_testonly = default_testonly,
        default_visibility = default_visibility,
        features = features,
    ))

def _alias(name, actual, visibility = None):
    """Build an `alias()` call, auto-formatted.

    See [alias](https://bazel.build/reference/be/general#alias).

    Args:
        name: Target name.
        actual: The actual target.
        visibility: Optional visibility.

    Returns:
        A pre-rendered Starlark string.
    """
    return gen.auto(fn.call(
        "alias",
        name = name,
        actual = actual,
        visibility = visibility,
    ))

def _exports_files(srcs, visibility = None, licenses = None):
    """Build an `exports_files()` call, auto-formatted.

    See [exports_files](https://bazel.build/reference/be/functions#exports_files).

    Args:
        srcs: Files to export.
        visibility: Optional visibility.
        licenses: Optional licenses.

    Returns:
        A pre-rendered Starlark string.
    """
    return gen.auto(fn.call(
        "exports_files",
        srcs,
        visibility = visibility,
        licenses = licenses,
    ))

def _bzl_library(name, srcs = None, deps = None, visibility = None):
    """Build a `bzl_library()` call, indented.

    See [bzl_library](https://github.com/bazelbuild/bazel-skylib/blob/main/docs/bzl_library.md).

    Args:
        name: Target name.
        srcs: Source `.bzl` files.
        deps: Dependencies.
        visibility: Optional visibility.

    Returns:
        A pre-rendered indented Starlark string.
    """
    return gen.igen(fn.call(
        "bzl_library",
        name = name,
        srcs = srcs,
        deps = deps,
        visibility = visibility,
    ))

bazel = struct(
    alias = _alias,
    bzl_library = _bzl_library,
    exports_files = _exports_files,
    glob = _glob,
    load_ = _load_,
    package = _package,
    select = _select,
)
