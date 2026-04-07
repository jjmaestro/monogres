"""
Repository rule for `sysroots.apt(...)` hub repos.

Each tag materializes one hub repo `@<name>` containing:

  - A package declaration at each of `<name>/`, `<distro>/`, `<version>/`.
  - One per-arch subpackage at `<distro>/<version>/<arch>/` exposing the
    extracted, normalized, patched sysroot two parallel ways: a `:sysroot`
    `filegroup(glob(["**"]))` (for `toolchains_llvm`'s `--sysroot=` consumer,
    which pulls files into action inputs via the label's `DefaultInfo`) and a
    sibling `:sysroot.tar` (single-file artifact for buildtime consumers that
    extract at action time and need files Bazel's target-name grammar can't
    represent as labels, e.g. `Dpkg::Arch.3perl.gz`).
  - A `<distro>/<version>/lock/` subpackage holding the resolved lockfile and
    a `:update` `sh_binary` that re-emits it back into the source tree.

The hub-as-single-repo shape (rather than alias-through-internal-repos) is
required by `toolchains_llvm` recording the label's package path verbatim as
`--sysroot=`; the per-arch subpackage has to contain the extracted files
directly.

Per-arch materialization runs every Tier-1 step in order. Download all `.deb`s
in lock order, two-stage extract via `rctx.download_and_extract(type="deb")` +
`rctx.extract` (no host `ar`/`tar`/`dpkg-deb` invocation needed), then
`normalize.prune_cyclic_symlinks` (cyclic `libllvm14`-style symlinks dropped),
`normalize.relativize_symlinks` (absolute symlink targets get rewritten
sysroot-absolute), `normalize.rewrite_ld_scripts` (GNU-ld scripts get the
`=`-prefix on every path), `known_patches.apply` (package-specific rewrites),
and `extra_files.apply` (Tier-2 per-tag file injection). The `:sysroot.tar`
snapshot is written next, then `prune_bazel_unrepresentable_paths` drops
`:`-in-basename files from the on-disk tree for filegroup safety. The per-arch
`BUILD.bazel` is emitted last with both targets.
"""

load("//apt/private:deb.bzl", _deb = "deb")
load("//apt/private:known_patches.bzl", _known_patches = "known_patches")
load(
    "//common:codegen.bzl",
    "distro_root_build",
    "hub_root_build",
    "lock_build",
    "sysroot_build",
    "update_script",
    "version_root_build",
)
load("//common:extra_files.bzl", _extra_files = "extra_files")
load("//common:normalize.bzl", _normalize = "normalize")

def _materialize_arch(rctx, arch_dir, arch, packages, extra_files_map, exports):
    """Download + extract + normalize + patch + inject extras for one arch.

    The sysroot tree gets exposed via two parallel targets:

      * `:sysroot`: a `filegroup(glob(["**"]))` for consumers that need the
        files plumbed into action inputs by Bazel (notably `toolchains_llvm`'s
        `--sysroot=` consumer, which records the label's package path verbatim).
      * `:sysroot.tar`: a single-file artifact capturing the full normalized
        tree (including files whose basenames Bazel can't represent as target
        names, e.g. `Dpkg::Arch.3perl.gz`). Consumers that extract at action
        time take this one to bypass the Bazel filename restrictions filegroup
        mode imposes.

    The tar is written AFTER all the normalizations and `extra_files` injection
    but BEFORE `prune_bazel_unrepresentable_paths`. Net effect: the on-disk tree
    (and the `:sysroot` filegroup over it) drops `:`-in-basename files; the tar
    retains them. `prune_cyclic_symlinks` runs before the tar too; cyclic
    symlinks have no compile/link value and would break any consumer that walks
    the extracted tree.

    Args:
        rctx: A `repository_ctx`.
        arch_dir: Hub-relative path for this arch's sysroot tree.
        arch: Arch name (`amd64`, `arm64`).
        packages: List of resolved package dicts filtered to this arch. Each
            dict carries `key`, `sha256`, `urls`, `name`, etc. (the lockfile
            schema).
        extra_files_map: `label_keyed_string_dict` from the tag. Applied after
            the Tier-1 normalizations.
        exports: List of in-sysroot paths to additionally `exports_files`-expose
            on the per-arch BUILD file. Each path becomes a label of the form
            `@<hub>//<distro>/<version>/<arch>:<path>`, addressable by direct
            consumers. Paths refer to files already present after extraction (no
            `{arch}` placeholder).
    """
    if not packages:
        fail("//sysroots/apt: no packages for arch %r in %s" % (arch, arch_dir))

    # Download + extract in lock-resolved order. Last-write-wins matches dpkg's
    # install-order semantics. `deb.download_and_extract` uses Bazel's native
    # `.deb` support; no `ar`/`tar`/`dpkg-deb` invocation needed.
    for pkg in packages:
        _deb.download_and_extract(
            rctx,
            urls = pkg["urls"],
            sha256 = pkg["sha256"],
            out_dir = arch_dir,
        )

    _normalize.prune_cyclic_symlinks(rctx, arch_dir)
    _normalize.relativize_symlinks(rctx, arch_dir)
    _normalize.rewrite_ld_scripts(rctx, arch_dir)
    _normalize.redirect_ld_scripts_usrmerge(rctx, arch_dir)
    _known_patches.apply(rctx, arch_dir, packages)

    extra_files_paths = []
    if extra_files_map:
        _extra_files.apply(rctx, arch_dir, arch, extra_files_map)
        extra_files_paths = [
            _extra_files.resolve_target_path("", arch, path).lstrip("/")
            for path in extra_files_map.values()
        ]

    # Snapshot the fully-normalized + extras-injected tree as a single tar.
    # Written here, before `prune_bazel_unrepresentable_paths`, so the tar
    # captures the complete payload. The on-disk tree is then pruned for
    # filegroup safety; the tar is unaffected because it's already closed.
    _make_sysroot_tar(rctx, arch_dir)

    _normalize.prune_bazel_unrepresentable_paths(rctx, arch_dir)

    rctx.file(
        "%s/BUILD.bazel" % arch_dir,
        sysroot_build(
            extra_files_paths = extra_files_paths,
            extra_exports = exports,
        ),
    )

_BSDTAR_LABELS = {
    "amd64": Label("@bsd_tar_toolchains_linux_amd64//:tar"),
    "arm64": Label("@bsd_tar_toolchains_linux_arm64//:tar"),
}

def _host_arch(rctx):
    arch = rctx.os.arch
    if arch in ("x86_64", "amd64"):
        return "amd64"
    if arch in ("aarch64", "arm64"):
        return "arm64"
    fail("//sysroots/apt: unsupported host arch %r" % arch)

def _make_sysroot_tar(rctx, arch_dir):
    """Snapshot `arch_dir` as `<arch_dir>/sysroot.tar`.

    Resolves `@bsd_tar_toolchains_<host_platform>//:tar` via
    `rctx.path(Label(...))` so the load-phase tar invocation is satisfied by the
    hermetic bsdtar downloaded by `tar.bzl`. Symlinks are stored as symlinks
    (bsdtar's `-c` default), matching the `relativize_symlinks` rewrites:
    sysroot-absolute targets are preserved verbatim and resolve correctly after
    a clean `tar -xf`.

    Args:
        rctx: A `repository_ctx`.
        arch_dir: Hub-relative path for the per-arch sysroot tree.
    """
    out = "%s/sysroot.tar" % arch_dir
    bsdtar = rctx.path(_BSDTAR_LABELS[_host_arch(rctx)])
    result = rctx.execute([
        str(bsdtar),
        "--create",
        "--file=%s" % out,
        "--exclude=./sysroot.tar",
        "-C",
        arch_dir,
        ".",
    ])
    if result.return_code != 0:
        fail(
            "//sysroots/apt: bsdtar failed for %s\nstdout:\n%s\nstderr:\n%s" % (
                arch_dir,
                result.stdout,
                result.stderr,
            ),
        )

def _materialize_lock(rctx, version_dir, info):
    """Emit the `lock/<lockfile>`, `lock/update.sh`, `lock/BUILD.bazel` triple.

    Skipped (no-op) when `info["lock_json"]` is empty or absent; callers that
    own the lockfile elsewhere (e.g. an extension that shares a single lockfile
    across many sub-hubs) pass an empty string and the hub gets no `lock/`
    subpackage.

    Args:
        rctx: A `repository_ctx`.
        version_dir: Hub-relative path for the (distro, version) directory.
        info: The version-level dict from `distros_json` carrying `lock_json`,
            `lock_path`, `lock_filename`. When `lock_json` is missing/empty the
            other two keys are also ignored.
    """
    if not info.get("lock_json"):
        return

    lock_dir = "%s/lock" % version_dir
    lock_filename = info["lock_filename"]
    rctx.file("%s/%s" % (lock_dir, lock_filename), info["lock_json"])
    rctx.file(
        "%s/update.sh" % lock_dir,
        update_script(info["lock_path"]),
        executable = True,
    )
    rctx.file("%s/BUILD.bazel" % lock_dir, lock_build(lock_filename))

def _hub_impl(rctx):
    distros = json.decode(rctx.attr.distros_json)
    rctx.file("BUILD.bazel", hub_root_build())

    for distro, versions in distros.items():
        rctx.file("%s/BUILD.bazel" % distro, distro_root_build())

        for version, info in versions.items():
            version_dir = "%s/%s" % (distro, version)
            rctx.file(
                "%s/BUILD.bazel" % version_dir,
                version_root_build(
                    distro_version = version_dir,
                    archs = sorted(info["archs"].keys()),
                ),
            )

            for arch, packages in info["archs"].items():
                arch_dir = "%s/%s" % (version_dir, arch)
                _materialize_arch(
                    rctx,
                    arch_dir,
                    arch,
                    packages,
                    rctx.attr.extra_files,
                    rctx.attr.exports,
                )

            _materialize_lock(rctx, version_dir, info)

hub_repo = repository_rule(
    implementation = _hub_impl,
    attrs = dict(
        distros_json = attr.string(
            mandatory = True,
            doc = (
                "JSON-encoded {distro: {version: {archs: {arch: [packages]}, " +
                "lock_json: str, lock_path: str, lock_filename: str}}}. " +
                "Each `packages` value is the lockfile's package list " +
                "filtered to that arch (carrying the lockfile's key, sha256, " +
                "urls, name, version fields)."
            ),
        ),
        extra_files = attr.label_keyed_string_dict(
            doc = (
                "Tier-2 file injection map. For each (source_label, " +
                "in_sysroot_path) pair, the source label's content is " +
                "written at sysroot_dir/in_sysroot_path with the executable " +
                "bit. The `{arch}` placeholder in the path is substituted " +
                "at write time."
            ),
        ),
        exports = attr.string_list(
            doc = (
                "Additional in-sysroot paths to `exports_files`-expose on " +
                "each per-arch BUILD file. Makes each path addressable as " +
                "`@<hub>//<distro>/<version>/<arch>:<path>`. Paths must NOT " +
                "include a `{arch}` placeholder; they refer to files already " +
                "present in every per-arch tree after extraction."
            ),
        ),
    ),
)
