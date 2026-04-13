"""`pg_install_tree`: assemble the native Postgres install tree.

It assembles a directory of REAL files laid out under bin/ lib/ share/ (the
prefix_distro layout), the same shape the regress harness consumes. It is a
single tree artifact, the same output shape the make flavor's `_install_tree`
produces, so the harness reaches it through its directory-tree path
(`bin/initdb` under the tree root) identically to either upstream build.

The files are copied, not symlinked, because Postgres relocates at run time by
resolving its own executable path (`find_my_exec` follows every symlink) and
deriving sharedir / libdir relative to the `.../bin/<exe>` it lands on. A
symlinked `bin/postgres` resolves out to the scattered cc_binary output (whose
parent is not `bin/`), relocation fails, and the backend falls back to the
compiled-in `/postgres/<version>/share`. A real file under `bin/` keeps
relocation working with no `-L` / `PGSHAREDIR` from the harness.

The copy runs as one hermetic `run_shell` action (busybox `cp` / `ln` / `mkdir`,
no archiver or python), driven by a written manifest so it scales to the whole
tree without a giant command line. libpq's soname / dev links (libpq.so.5 ->
libpq.so.5.16) are emitted as relative symlinks inside the tree, the way an
install creates them.
"""

# One hermetic copy action lays the whole tree out from a manifest. Each line is
# tab-separated `<kind>\t<a>\t<b>`: `F` copies the real file at exec-relative
# path <a> to tree-relative <b>; `L` makes the relative symlink <a> -> <b>
# inside the tree (libpq's soname / dev links). `cp -L` dereferences so the tree
# holds real content even when Bazel stages an input as a symlink.
#
# An optional `base` tree is laid down first (`cp -a`, preserving the base's own
# real files and within-tree symlinks), then this tree's manifest overlays it.
# That composes a layer (e.g. `:tar.test` over the production `:tar`) the way an
# OCI image stacks layers, without duplicating the base's file list.
#
# An optional `exclude` list then carves paths back out of the composed tree
# (shell-globbed `rm -rf`), so a runtime subset can be derived from a full base:
# `:tar` drops the dev-only paths (headers, pgxs, pkg-config, static archives)
# the meson `:tar.dev` keeps.
_INSTALL_CMD = """\
set -eu
mkdir -p "{out}"
if [ -n "{base}" ]; then
    cp -a "{base}/." "{out}/"
    chmod -R u+w "{out}"
fi
{excludes}
while IFS="$(printf '\\t')" read -r kind a b; do
    case "$kind" in
        F)
            mkdir -p "{out}/$(dirname "$b")"
            cp -L "$a" "{out}/$b"
            ;;
        L)
            mkdir -p "{out}/$(dirname "$a")"
            ln -s "$b" "{out}/$a"
            ;;
    esac
done < "{manifest}"
"""

def _pg_install_tree_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)

    inputs = []
    base_path = ""
    if ctx.attr.base:
        base_files = ctx.files.base
        if len(base_files) != 1:
            fail(
                "pg_install_tree: base must provide exactly one tree, got %d" % len(base_files),
            )
        base_path = base_files[0].path
        inputs.append(base_files[0])

    if ctx.attr.exclude and not ctx.attr.base:
        fail("pg_install_tree: exclude requires base (it carves the base tree)")
    exclude_cmd = ""
    if ctx.attr.exclude:
        # Carve a runtime subset from the copied base: drop the dev-only paths
        # (shell-globbed, e.g. lib/*.a) so :tar stays runtime while :tar.dev
        # keeps them.
        exclude_cmd = '(cd "%s" && rm -rf %s)' % (out.path, " ".join(
            ctx.attr.exclude,
        ))

    lines = []
    for target, dest in ctx.attr.files.items():
        srcs = target.files.to_list()
        if len(srcs) != 1:
            fail("pg_install_tree: %s must provide exactly one file, got %d" % (
                target.label,
                len(srcs),
            ))
        f = srcs[0]
        inputs.append(f)
        lines.append("F\t%s\t%s" % (f.path, dest))
    for target, dest_dir in ctx.attr.subdir_files.items():
        for f in target.files.to_list():
            inputs.append(f)
            lines.append("F\t%s\t%s/%s" % (f.path, dest_dir, f.basename))
    for target, spec in ctx.attr.tree_files.items():
        marker, dest_prefix = spec.split("::", 1)
        for f in target.files.to_list():
            idx = f.path.find(marker)
            if idx < 0:
                fail("pg_install_tree: marker %r not in %s" % (marker, f.path))
            inputs.append(f)
            lines.append(
                "F\t%s\t%s/%s" % (f.path, dest_prefix, f.path[idx + len(
                    marker,
                ):]),
            )
    for link, target_path in ctx.attr.symlinks.items():
        lines.append("L\t%s\t%s" % (link, target_path))

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, "\n".join(lines) + "\n")

    ctx.actions.run_shell(
        inputs = inputs + [manifest],
        outputs = [out],
        command = _INSTALL_CMD.format(
            out = out.path,
            manifest = manifest.path,
            base = base_path,
            excludes = exclude_cmd,
        ),
        mnemonic = "PgInstallTree",
        progress_message = "Assembling PG install tree %{output}",
    )

    return [
        DefaultInfo(files = depset([out])),
        OutputGroupInfo(gen_dir = depset([out])),
    ]

pg_install_tree = rule(
    implementation = _pg_install_tree_impl,
    doc = "Lay artifacts out as real files at their install-relative paths " +
          "(bin/ lib/ share/ ...) in one tree artifact, the native Postgres " +
          "install tree.",
    attrs = {
        "base": attr.label(
            allow_files = True,
            doc = "Optional base tree laid down first (cp -a, preserving its " +
                  "files + symlinks) before this tree's files overlay it; the " +
                  "layer-composition input (e.g. the test tree over :tar).",
        ),
        "exclude": attr.string_list(
            doc = "Relative path globs removed from the composed tree after the " +
                  "base is laid down, deriving a runtime subset from a full base " +
                  "(drop headers / pgxs / pkg-config / static archives). " +
                  "Requires base; shell-globbed (e.g. lib/*.a).",
        ),
        "files": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Map of single-file artifact -> install-relative path.",
        ),
        "subdir_files": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Map of a multi-file target (a glob filegroup) -> dest dir; " +
                  "each file installs to <dest dir>/<basename> (meson " +
                  "install_subdir, for the flat text-search data dirs).",
        ),
        "symlinks": attr.string_dict(
            doc = "Map of install-relative symlink path -> (relative) target.",
        ),
        "tree_files": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Map of a multi-file target -> 'MARKER::DEST': each file " +
                  "installs to DEST/<path after the first MARKER in its source " +
                  "path>, preserving the nested directory layout (meson " +
                  "install_subdir of a header tree, which flat subdir_files " +
                  "would collapse).",
        ),
    },
)
