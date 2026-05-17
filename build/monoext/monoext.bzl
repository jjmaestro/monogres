"""
# `monoext`: Monogres module extension

This is the single module extension that downstream users need to bring the
monogres-managed repos into scope:

```starlark
monoext.monogres(
    name = "pg",
    base = "//catalog/postgres:repo.json",
    extensions = "//catalog/extensions:index.json",  # optional
    deb_lock = "//catalog/locks:pg_pkgs.lock",       # optional
)
```

The `name` attribute drives all derived repo names:
  - `@{name}`: base hub repo (PostgreSQL is the current flavor).
  - `@{name}_ext`: extensions hub repo (only when `extensions` is set).
  - `@{name}_pkgs`: shared package dependency pool.

Internal repos:
  - `@{name}_src`: base source index repo (lazy per-version downloads).
  - `@{name}_src-{v}`: per-version base source (download_archives
    convention).
  - `@{name}_introspect--{v}`: per-version introspect repo (lazy).
  - `@{name}_ext_src--{ext}`: per-extension source repo (lazy).
  - `@{name}_pkgs_deb`: internal deb_translate_lock repo.
"""

load("@platform_debian//:versions.bzl", "RELEASE")
load("@sysroots//common:tag_key.bzl", "tag_key")
load("//monoext/private:base.bzl", "create_base", "create_base_src")
load("//monoext/private:ext.bzl", "create_ext", "create_ext_src")
load("//monoext/private:pkgs.bzl", "LLVM_PREREQS", "create_pkgs")
load("//monoext/private:repo_names.bzl", "repo_names")
load("//monoext/private/apt:apt_lock.bzl", "SNAPSHOT", _AptLock = "apt_lock")
load("//monoext/private/pkgs:schema.bzl", "KINDS")
load("//platforms:targets.bzl", "ARCHS")

def create_monogres(
        ctx,
        name,
        base,
        extensions = None,
        deb_lock = None,
        build_repo = "monogres"):
    """Creates the full monogres repo ecosystem.

    This is the public API for creating monogres-managed repos. It can be called
    directly from another module extension's implementation (since Bazel doesn't
    allow module extensions to call other module extensions).

    Args:
        ctx: Module extension context.
        name: Hub name prefix (e.g. `"pg"`). Drives all derived repo
            names: `@{name}`, `@{name}_pkgs`, `@{name}_ext`, plus internal repos
                `@{name}_src`, `@{name}_introspect_{v}`, etc.
        base: Label of the base flavor's `repo.json` (currently PostgreSQL).
        extensions: Label of the extensions catalog `index.json` (optional).
        deb_lock: Label of the deb lockfile (optional). When set, skips live
            Debian package resolution. See `//apt:apt_lock.bzl`.
        build_repo: Repo containing build rules (default `"monogres"`).

    Returns:
        List of created repo names (for `root_module_direct_deps`).
    """
    pkgs_name = repo_names.pkgs_hub(name)
    ext_name = repo_names.ext_hub(name)

    # 1. base sources: @{name}_src, @{name}_introspect_{v}
    base_data = create_base_src(ctx, name, base)

    # 2. extension sources (+ catalog read): @{name}_ext_src__{ext}
    ext_data = create_ext_src(
        ctx,
        ext_name,
        extensions,
        base_flavor = base_data.flavor,
    )

    package_groups = [base_data.pkgs_group] + list(ext_data.pkgs_groups)

    # 3. read + validate lockfile (if provided)
    lock = None
    if deb_lock:
        lock = _AptLock.decode(ctx.read(deb_lock))

        # LLVM_PREREQS is the compile-time floor `create_pkgs` adds to every
        # buildtime hub's closure. The lockfile MUST already have them — without
        # it, the buildtime hubs would silently come out missing `crt*.o` /
        # `libgcc*` (citus 13.2.0 link check surfaces this).
        error = _AptLock.validate(
            lock,
            snapshot = SNAPSHOT,
            archs = list(ARCHS),
            requested_packages = (
                _collect_all_packages(package_groups) + LLVM_PREREQS
            ),
        )
        if error:
            # buildifier: disable=print
            print((
                "WARNING: apt lockfile for '%s' is stale (%s). " +
                "Falling back to live resolution.\n" +
                "Regenerate with: bazel run @%s//deb/lock:update"
            ) % (pkgs_name, error, pkgs_name))
            lock = None

    # 4. shared deps pool: @{name}_pkgs
    pkgs_result = create_pkgs(ctx, pkgs_name, package_groups, lock = lock)

    # 5. base hub: @{name}
    create_base(
        hub_name = name,
        base_data = base_data,
        pkgs_result = pkgs_result,
        archs = ARCHS,
        build_repo = build_repo,
    )

    repos = [name, pkgs_name]

    # 6. extensions hub: @{name}_ext (if extensions set)
    if extensions:
        create_ext(
            hub_name = ext_name,
            extensions = ext_data.extensions,
            pkgs_result = pkgs_result,
            catalog = extensions,
            base_versions = base_data.versions,
            base_hub_name = name,
            base_flavor = base_data.flavor,
            archs = ARCHS,
            build_repo = build_repo,
        )
        repos.append(ext_name)

    return repos

def _collect_all_packages(package_groups):
    """Collects all unique requested package names for lockfile validation."""

    def get_packages(metadata, kind):
        # deps.<kind>.debian is release-keyed; validate the active release.
        debian = metadata.get("deps", {}).get(kind, {}).get("debian", {})
        return debian.get(RELEASE.version, {}).values()

    all_pkgs = [
        pkg
        for group in package_groups
        for kind in KINDS
        for packages in get_packages(group.metadata, kind)
        for pkg in packages
    ]
    return sorted(set(all_pkgs))

def _monoext_impl(ctx):
    direct_deps = []
    seen = {}

    for module in ctx.modules:
        for tag in module.tags.monogres:
            key = tag_key(tag, exclude = ["name", "deb_lock"])
            prev = seen.get(tag.name)

            if prev:
                if prev.key != key:
                    msg = (
                        "Monogres name %r conflict: %r and %r " +
                        "declared with different values"
                    )
                    fail(msg % (tag.name, prev.module, module.name))

                continue

            seen[tag.name] = struct(key = key, module = module.name)

            direct_deps += create_monogres(
                ctx = ctx,
                name = tag.name,
                base = tag.base,
                extensions = tag.extensions,
                deb_lock = tag.deb_lock,
                build_repo = tag.build_repo,
            )

    return ctx.extension_metadata(
        reproducible = True,
        root_module_direct_deps = sorted(direct_deps),
        root_module_direct_dev_deps = [],
    )

_monogres_tag = tag_class(
    attrs = dict(
        name = attr.string(mandatory = True),
        base = attr.label(mandatory = True),
        extensions = attr.label(),
        deb_lock = attr.label(),
        build_repo = attr.string(default = "monogres"),
    ),
)

monoext = module_extension(
    implementation = _monoext_impl,
    tag_classes = dict(
        monogres = _monogres_tag,
    ),
)
