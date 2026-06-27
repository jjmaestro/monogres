"""Repository rule for the native cc_* Postgres overlay
    (`@<hub>_cc_<v>_<set>`).

Modeled on `introspect.bzl`'s Layer 2 repo rule. Resolves the patched
per-version source (resolving the label triggers its lazy download) and merges
the source tree into the overlay root along the package spine: the target-owning
directories from `overlay_layout` and their ancestors become real directories
whose children are symlinked individually (so a generated BUILD file can sit
beside the source there), while every other subtree is one symlink. The cc_*
targets reference source files as overlay-relative labels (`src/backend/...`)
and include dirs like `src/include` resolve against both the source and the
genfiles tree. It drops in the captured config-header seed under
`config_headers/`, exposes the buildtime sysroot under `sysroot/`, then renders
the overlay BUILD from the committed introspect JSON (see
`//monoext/private/cc_overlay:render.bzl`).

This is overlay placement option (A) from analysis section 6.2: the BUILD
overlay is rendered into a repo that carries the source, so globbing and include
math stay trivial. The source-path handling is isolated here, so a later switch
to a separate-repo layout (option B) stays local.
"""

load("//monoext/private/cc_overlay:layout.bzl", "overlay_layout")
load("//monoext/private/cc_overlay:render.bzl", "render_overlay")

def _build_spine(packages):
    """The directories that stay real (not whole-subtree symlinks) in the overlay.

    A package and every ancestor must be a real directory so a per-package BUILD
    file can sit beside the source; every other subtree is symlinked whole.

    Args:
        packages: the overlay package paths (from overlay_layout).

    Returns:
        A set (dict with True values) of the spine directories.
    """
    spine = {}
    for p in packages:
        cur = ""
        for seg in p.split("/"):
            cur = seg if not cur else cur + "/" + seg
            spine[cur] = True
    return spine

def _merge_symlinks(rctx, src_root, spine):
    """Symlink the source tree into the overlay, fine-grained along the spine.

    Spine directories become real directories whose children are symlinked
    individually (so a generated BUILD file can later sit beside the source
    there); every off-spine subtree is symlinked as a single symlink, which
    keeps the merge fast. Behavior-preserving: every source file ends up at the
    same overlay-relative path either way. Starlark forbids recursion, so the
    walk is an explicit stack bounded by a generous iteration cap.

    Args:
        rctx: the repository context.
        src_root: the source tree root (a path).
        spine: the spine directory set (from _build_spine).
    """
    stack = [("", src_root)]
    for _ in range(100000):
        if not stack:
            break
        rel, path = stack.pop()
        for child in path.readdir():
            name = child.basename
            crel = name if not rel else rel + "/" + name
            if rel == "" and name == "BUILD.bazel":
                # The download_archives root BUILD occupies the slot the
                # generated root BUILD needs.
                continue
            if crel in spine:
                stack.append((crel, child))
            else:
                rctx.symlink(child, crel)

def _pg_cc_overlay_impl(rctx):
    introspect = json.decode(rctx.read(rctx.attr.introspect_json))
    layout = overlay_layout(introspect)

    # Merge the patched source tree into the overlay root, fine-grained along
    # the package spine. `pg_src_version_dir` points at the source repo's
    # BUILD.bazel; its dirname is the source root, whose resolution triggers the
    # per-version source download.
    src_dir = rctx.path(rctx.attr.pg_src_version_dir).dirname
    _merge_symlinks(rctx, src_dir, _build_spine(layout.packages))

    # Drop the captured config-header seed (pg_config*.h) into config_headers/.
    # `config_headers` points at one seed header; its dirname is the seed dir.
    ch_dir = rctx.path(rctx.attr.config_headers).dirname
    for header in ch_dir.readdir():
        if header.basename.endswith(".h"):
            rctx.symlink(header, "config_headers/" + header.basename)

    # Expose the per-PG buildtime sysroot under sysroot/ so both the
    # external-dependency headers (openssl, icu, libxml2, ... under usr/include)
    # the compile #includes resolve AND the shared libraries (under usr/lib,
    # lib) the backend / frontends link against are overlay-relative inputs.
    # `buildtime_sysroot_build` is the sysroot package's BUILD.bazel; its
    # dirname is the sysroot root. The content subdirs are symlinked
    # individually (not the root) because the root holds that BUILD.bazel, which
    # would make `sysroot/` a subpackage and fence off `sysroot/...` from this
    # package's globs and labels. usr + lib + lib64 together resolve every
    # overlay-relative `sysroot/...` path (including the usr/lib -> ../../../lib
    # relative .so symlinks) and mirror the introspect's own
    # `<BAZEL-BUILD>/sysroot/...` references.
    sysroot_root = rctx.path(rctx.attr.buildtime_sysroot_build).dirname
    for child in ["usr", "lib", "lib64"]:
        rctx.symlink(sysroot_root.get_child(child), "sysroot/" + child)

    # Render one BUILD per overlay package (the per-directory layout). An empty
    # package set collapses every target into the root BUILD; the real set
    # (layout.packages) splits the overlay across the source tree. The package
    # dirs are already real directories (the spine merge above), so a generated
    # BUILD can sit beside the symlinked source in each.
    builds = render_overlay(
        introspect,
        rctx.attr.version,
        rctx.attr.option_set,
        layout.packages,
        # The cc actions compile from `external/<canonical repo>/<pkg-rel>`;
        # `rctx.name` is that canonical repo name, so the renderer can strip the
        # `external/<repo>/` prefix out of `__FILE__` to the package-relative
        # path (`src/...`, `contrib/...`).
        src_prefix = "external/%s/" % rctx.name,
    )
    for pkg, content in builds.items():
        rctx.file((pkg + "/BUILD.bazel") if pkg else "BUILD.bazel", content)

pg_cc_overlay = repository_rule(
    implementation = _pg_cc_overlay_impl,
    doc = "Generate a native cc_* Postgres build overlay for one " +
          "(version, option_set) from the committed introspect JSON + the " +
          "captured config-header seed, co-located with the symlinked source.",
    attrs = dict(
        version = attr.string(mandatory = True),
        option_set = attr.string(mandatory = True),
        pg_src_version_dir = attr.label(
            mandatory = True,
            doc = "BUILD.bazel label in the per-version source repo " +
                  "(e.g. @pg_src-16.0//16.0/gh:BUILD.bazel); its dirname is the " +
                  "source root symlinked into the overlay.",
        ),
        introspect_json = attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Committed introspect JSON for this (version, option_set).",
        ),
        config_headers = attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "One captured config-header seed file; its dirname holds the " +
                  "(version, option_set, arch) pg_config*.h set.",
        ),
        buildtime_sysroot_build = attr.label(
            mandatory = True,
            doc = "BUILD.bazel label in the per-arch buildtime sysroot package " +
                  "(e.g. @pgbuildtime_<key>//debian/12/amd64:BUILD.bazel); its " +
                  "dirname is the sysroot root whose usr/include holds the " +
                  "external-dep headers and whose usr/lib / lib hold the shared " +
                  "libraries the backend / frontends link against.",
        ),
    ),
)
