"""
Pick one binary out of the Rust toolchain tree.

The toolchain arrives as one filegroup per target triple, and an action that
runs `cargo` needs a label resolving to exactly that file: `execpath` of a
filegroup is only defined for a single-file one, and the tree's own path is a
canonical repo name no source file spells out. Everything else (`rustc`,
`rustfmt`, the `rust-std` libraries) is found by cargo relative to its own
prefix, so one binary is the only handle needed.
"""

def _rust_bin_impl(ctx):
    suffix = "/bin/" + ctx.attr.bin
    matches = [f for f in ctx.files.toolchain if f.path.endswith(suffix)]

    if len(matches) != 1:
        fail("%s: expected one *%s in %s, found %d" % (
            ctx.label,
            suffix,
            ctx.attr.toolchain.label,
            len(matches),
        ))

    return DefaultInfo(files = depset(matches))

rust_bin = rule(
    doc = """
    A single Rust toolchain binary, as a one-file target.

    The toolchain tree itself is not carried along: an action that runs the
    binary stages `//toolchains/rust:files` too, since cargo reads the rest of
    the prefix at runtime.
    """,
    attrs = dict(
        bin = attr.string(
            doc = "Binary name under the toolchain's `bin/`.",
            mandatory = True,
        ),
        toolchain = attr.label(
            doc = "The toolchain tree to pick from.",
            allow_files = True,
            mandatory = True,
        ),
    ),
    implementation = _rust_bin_impl,
)
