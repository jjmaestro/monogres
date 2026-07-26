"""
Build-arg substitution shared by the external-extension build rules.

`metadata.build_args` entries carry portable tokens (`{pg_config}`, `{sysroot}`)
that resolve to action-time sysroot paths, so a `repo.json` can name a path
(e.g. a config tool at `{sysroot}/usr/bin/foo-config`) without hard-coding the
action's sandbox layout. The token maps live here, not in the per-build-system
rules, so `pgxs.bzl` / `cmake.bzl` stay generic engines that apply an opaque
substitution table.

Each map's right-hand side references a bash local the corresponding build
action defines in scope where the args are consumed. `$$` survives `.format()`
and Bazel collapses it to `$`, so no `{}`-escaping leaks into the genrule cmd.
"""

# PGXS (autoconf/make) tokens: resolve to `compile_extension()` locals in
# `pgxs.bzl` (`abs_pg_install_dir`, `sysroot_dir`).
PGXS_ARG_SUBST = {
    "{pg_config}": "$$abs_pg_install_dir/bin/pg_config",
    "{sysroot}": "$$sysroot_dir",
}

# CMake tokens: resolve to `compile_extension()` locals in `cmake.bzl`
# (`abs_pg_install_dir`).
CMAKE_ARG_SUBST = {
    "{pg_config}": "$$abs_pg_install_dir/bin/pg_config",
}

def render_build_args(build_args, subst, indent):
    """Renders `build_args` as the body of a bash array (or empty string).

    Each entry has its portable tokens replaced per `subst`, then is emitted as
    a double-quoted array element. Elements are joined by a newline plus
    `indent` spaces; the caller's template supplies the indent for the first
    element (so the placeholder lines up with the array's other entries in the
    emitted cmd). An empty `build_args` renders to `""`.

    Args:
        build_args (list[str]): The extension's `metadata.build_args`.
        subst (dict[str, str]): Portable-token -> action-time value map.
        indent (int): Leading spaces for the second and later elements.

    Returns:
        The rendered bash-array body, or "" when `build_args` is empty.
    """
    elements = []
    for arg in build_args:
        for token, repl in subst.items():
            arg = arg.replace(token, repl)
        elements.append('"%s"' % arg)
    return ("\n" + " " * indent).join(elements)

def render_remap_paths(remap_paths, subst, indent):
    """Renders `remap_paths` as a sequence of `remap_paths` shell calls.

    For each `{file_pattern: {from: to}}` entry emits one `remap_paths
    "$sysroot_dir" "<pattern>" "<from>" "<to>"` call, with the portable tokens
    in `from` / `to` replaced per `subst`. Calls are joined by a newline plus
    `indent` spaces; the caller's template supplies the indent for the first
    call. An empty `remap_paths` renders to `""`.

    Args:
        remap_paths (dict[str, dict[str, str]]): The extension's
            `metadata.remap_paths` (`{file_pattern: {from: to}}`).
        subst (dict[str, str]): Portable-token -> action-time value map.
        indent (int): Leading spaces for the second and later calls.

    Returns:
        The rendered shell calls, or "" when `remap_paths` is empty.
    """
    calls = []
    for pattern in remap_paths:
        for frm, to in remap_paths[pattern].items():
            for token, repl in subst.items():
                frm = frm.replace(token, repl)
                to = to.replace(token, repl)
            calls.append(
                'remap_paths "$$sysroot_dir" "%s" "%s" "%s"' % (pattern, frm, to),
            )
    return ("\n" + " " * indent).join(calls)
