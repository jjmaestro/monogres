"""
Assemble a cargo directory source (a vendor tree) out of crate pool repos.

Cargo can be pointed at a directory holding one subdirectory per package
(`<crate>-<version>/`, each with its `.cargo-checksum.json`) and told to resolve
`crates-io` from there instead of the network. That is the only offline
resolution mode that needs no registry index, so it is what the pgrx builds use.

The pool gives one repo per crate release (see `crate_repo.bzl`); this gathers a
lock's worth of them into one tree and emits it as a tar, the way the sysroots
travel as tars. One tar per (extension, version) is built once and extracted by
each of the PG majors that extension builds for, since the closure is identical
across majors (a major is only a cargo feature).

A crate's directory is found through its `Cargo.toml`: every crate has one at
its root, and its `execpath` is the only handle a generated BUILD file has on a
package whose canonical repo name it never spells out.
"""

_CMD = """
set -eu

vendor="$$PWD/{name}.vendor"
mkdir -p "$$vendor"

# Copy one crate out of its pool repo. `-L` dereferences: the action's inputs
# are symlinks into the sandbox, and a tar of those would archive links to paths
# that stop existing when the action does.
stage() {{
    cp -RL "$$(dirname "$$2")" "$$vendor/$$1"
}}

{stage_calls}

LC_ALL=C {tar_cmd} \
    -cf "$$PWD/{tar_out}" \
    {tar_args} \
    --directory "$$vendor" \
    .
"""

# Same reproducible-archive settings the extension builds tar with.
_TAR_ARGS = ["--format=posix", "--numeric-owner", "--owner=0", "--group=0"]

def cargo_vendor(name, crates, visibility = None):
    """Emits a genrule tarring a cargo directory source for `crates`.

    Args:
        name: Target name; the output is `<name>.tar`.
        crates: `{package: dir_name}` as returned by `pool.declare`: the pool
            package holding each crate, as a label prefix, and the
            `<crate>-<version>` directory it takes in the tree.
        visibility: Target visibility.
    """
    tar_out = "%s.tar" % name
    manifests = ["%s:Cargo.toml" % crate for crate in crates]

    native.genrule(
        name = name,
        srcs = ["%s:files" % crate for crate in crates] + manifests,
        outs = [tar_out],
        cmd = _CMD.format(
            name = name,
            stage_calls = "\n".join([
                'stage "%s" "$(execpath %s)"' % (dir_name, manifests[i])
                for i, dir_name in enumerate(crates.values())
            ]),
            tar_cmd = "$(BSDTAR_BIN)",
            tar_out = "$(location %s)" % tar_out,
            tar_args = " ".join(_TAR_ARGS),
        ),
        toolchains = ["@bsd_tar_toolchains//:resolved_toolchain"],
        visibility = visibility,
    )
