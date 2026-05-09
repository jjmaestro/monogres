"""
Schema for `pkgs`-layer data.

Defines:

- `DepsInfo`: one deps bundle (`{packages, pkgs_labels,
  sysroot_labels_by_arch}`) produced by `//monoext/private:pkgs.bzl` when
  mapping resolved apt groups back to per-extension versions.
- `VersionDeps`: a `{buildtime, runtime}` pair of optional `DepsInfo`s.
- `TargetDeps`: consumer-facing projection of `VersionDeps` with
  qualified `@hub//{prefix}/deps/...` alias labels. Baked onto each
  `BaseTarget.deps` and `ExtExternalEntry.deps` before the JSON boundary so the
  hub repo rules render straight from the schema.
- `PkgsResult`: the return value of `create_pkgs()`, carrying the
  global `package_name_map` and the nested `versions_deps` map.

`DepsInfo`, `VersionDeps`, and `TargetDeps` all cross the base / ext JSON
boundary via `base_repo.entries` and `ext_repo.entries`, so they ship with `new`
and `from_dict` helpers.
"""

load("//monoext/private:repo_names.bzl", "bind")

# Canonical iteration order of the `VersionDeps` / `TargetDeps` kinds. Internal
# consumers (writers, collectors) loop over this constant instead of inlining
# the tuple; see `schema.KINDS` at the bottom.
KINDS = ("buildtime", "runtime")

def _deps_info_new(
        packages = [],
        pkgs_labels = [],
        sysroot_labels_by_arch = {},
        sysroot_tar_labels_by_arch = {}):
    """Constructs a `DepsInfo`.

    Args:
        packages: Sorted list of originally-requested package names for this
            deps kind.
        pkgs_labels: Parallel list of per-package `@pkgs//deb/...` labels.
        sysroot_labels_by_arch: Per-arch `{arch: label}` map of `@pgbuildtime_
            <key>//<distro>/<version>/<arch>:sysroot` filegroup labels produced
            by `//sysroots/apt`. Empty when the group has no sysroot.
        sysroot_tar_labels_by_arch: Per-arch `{arch: label}` map of
            `@pgbuildtime _<key>//<distro>/<version>/<arch>:sysroot.tar`
            single-file labels produced by `//sysroots/apt`. Parallel to
            `sysroot_labels_by_arch`; consumers that extract at action time take
            the tar variant.

    Returns:
        A `struct(packages, pkgs_labels, sysroot_labels_by_arch,
        sysroot_tar_labels_by_arch)`.
    """
    return struct(
        packages = packages,
        pkgs_labels = pkgs_labels,
        sysroot_labels_by_arch = sysroot_labels_by_arch,
        sysroot_tar_labels_by_arch = sysroot_tar_labels_by_arch,
    )

def _deps_info_from_dict(d):
    """Builds a `DepsInfo` from a decoded JSON dict, or `None` if absent.

    Returns `None` for empty / missing dicts because `DepsInfo` models optional
    presence: `VersionDeps.buildtime` and `.runtime` are each either a
    `DepsInfo` or `None`.
    """
    if not d:
        return None
    return _deps_info_new(
        packages = d.get("packages", []),
        pkgs_labels = d.get("pkgs_labels", []),
        sysroot_labels_by_arch = d.get("sysroot_labels_by_arch", {}),
        sysroot_tar_labels_by_arch = d.get("sysroot_tar_labels_by_arch", {}),
    )

def _version_deps_new(buildtime = None, runtime = None):
    """Constructs a `VersionDeps`.

    Args:
        buildtime: `DepsInfo` for build-time deps, or `None`.
        runtime: `DepsInfo` for run-time deps, or `None`.

    Returns:
        A `struct(buildtime, runtime)`.
    """
    return struct(
        buildtime = buildtime,
        runtime = runtime,
    )

def _version_deps_from_dict(d):
    """Builds a `VersionDeps` from a decoded JSON dict.

    Returns a zero-value `VersionDeps(None, None)` for empty / missing dicts
    because `VersionDeps` is always present on `BaseEntry` and each
    `BaseTarget`.
    """
    d = d or {}
    return _version_deps_new(
        buildtime = _deps_info_from_dict(d.get("buildtime")),
        runtime = _deps_info_from_dict(d.get("runtime")),
    )

def _target_deps_kind_new(
        sysroot = None,
        sysroot_tar = None,
        exec_sysroot_tar = None,
        packages = None):
    """Constructs one kind of a `TargetDeps` (`buildtime` or `runtime`).

    Args:
        sysroot: Qualified `@hub//.../deps/{kind}:sysroot` alias label, or
            `None` when the kind has no deps.
        sysroot_tar: Qualified `@hub//.../deps/{kind}:sysroot_tar` alias label,
            or `None` when the kind has no deps. Parallel to `sysroot`; points
            at the upstream `:sysroot.tar` single-file artifact.
        exec_sysroot_tar: Qualified `@hub//.../deps/{kind}:exec_sysroot_tar`
            label (an `exec_files`-wrapped `:sysroot_tar`), or `None` when the
            kind isn't `buildtime`. Resolves to the EXEC host arch's tar
            regardless of `--platforms`; consumers `srcs`-dep this in parallel
            with `sysroot_tar` for cross-builds to materialize a host-arch
            sysroot tree carrying build-machine tools (msgfmt, etc.) while
            target libs come from the TARGET-config tar.
        packages: List of qualified `@hub//.../deps/{kind}/pkgs:{pkg}` alias
            labels, or empty.

    Returns:
        A `struct(sysroot, sysroot_tar, exec_sysroot_tar, packages)`.
    """
    return struct(
        sysroot = sysroot,
        sysroot_tar = sysroot_tar,
        exec_sysroot_tar = exec_sysroot_tar,
        packages = packages if packages else [],
    )

def _target_deps_new(buildtime = None, runtime = None):
    """Constructs a `TargetDeps`.

    Args:
        buildtime: `struct(sysroot, packages)` for the buildtime kind, or `None`
            for the empty-kind default.
        runtime: `struct(sysroot, packages)` for the runtime kind, or `None` for
            the empty-kind default.

    Returns:
        A `struct(buildtime, runtime)` with both kinds always present (empty
        defaults for missing kinds) so downstream consumers see a uniform shape.
    """
    return struct(
        buildtime = buildtime if buildtime else _target_deps_kind_new(),
        runtime = runtime if runtime else _target_deps_kind_new(),
    )

def _target_deps_qualify(target_prefix, version_deps):
    """Projects a `VersionDeps` into a consumer-facing `TargetDeps`.

    Args:
        target_prefix: Hub-qualified label prefix up to but not including
            `/deps/...`, built via `names.pg_target_prefix` /
            `names.ext_target_prefix`.
        version_deps: `VersionDeps` struct (or `None`). Each kind (if populated)
            becomes `struct(sysroot, packages)` carrying qualified
            `{target_prefix}/deps/{kind}:sysroot` and
            `{target_prefix}/deps/{kind}/pkgs:{pkg}` alias labels.

    Returns:
        A `TargetDeps` struct.
    """
    vd = version_deps if version_deps else _version_deps_new()
    return _target_deps_new(
        buildtime = _qualify_kind(target_prefix, "buildtime", vd.buildtime),
        runtime = _qualify_kind(target_prefix, "runtime", vd.runtime),
    )

def _qualify_kind(target_prefix, kind, deps_info):
    if not deps_info:
        return _target_deps_kind_new()
    f = bind(prefix = target_prefix, kind = kind)
    packages = []
    for pkg in deps_info.packages:
        fp = bind(prefix = target_prefix, kind = kind, pkg = pkg)
        packages.append(fp("{prefix}/deps/{kind}/pkgs:{pkg}"))

    # `exec_sysroot_tar` only emitted for `buildtime` (where the
    # `:exec_sysroot_tar` companion alias is rendered by
    # `monoext/private/base/versions.bzl::write_base_version`); other kinds
    # leave it `None`.
    exec_sysroot_tar = None
    if kind == "buildtime":
        exec_sysroot_tar = f("{prefix}/deps/{kind}:exec_sysroot_tar")

    return _target_deps_kind_new(
        sysroot = f("{prefix}/deps/{kind}:sysroot"),
        sysroot_tar = f("{prefix}/deps/{kind}:sysroot_tar"),
        exec_sysroot_tar = exec_sysroot_tar,
        packages = packages,
    )

def _target_deps_from_dict(d):
    """Builds a `TargetDeps` from a decoded JSON dict.

    Mirror of `target_deps.qualify()` for the decode side of the JSON boundary;
    both kinds are always present so consumers see a uniform shape even when the
    original input was empty.
    """
    d = d or {}
    return _target_deps_new(
        buildtime = _kind_from_dict(d.get("buildtime")),
        runtime = _kind_from_dict(d.get("runtime")),
    )

def _kind_from_dict(d):
    d = d or {}
    return _target_deps_kind_new(
        sysroot = d.get("sysroot"),
        sysroot_tar = d.get("sysroot_tar"),
        exec_sysroot_tar = d.get("exec_sysroot_tar"),
        packages = d.get("packages", []),
    )

def _pkgs_result_new(package_name_map = {}, versions_deps = {}):
    """Constructs a `PkgsResult`.

    Args:
        package_name_map: `{requested_name: resolved_name}` for virtual package
            substitutions (forwarded from `AptResult`).
        versions_deps: Nested `{group_name: {version: VersionDeps}}` map with
            one entry per contributing group (e.g. `"postgres"`, each extension
            name).

    Returns:
        A `struct(package_name_map, versions_deps)`.
    """
    return struct(
        package_name_map = package_name_map,
        versions_deps = versions_deps,
    )

def _pkgs_result_from_dict(d):
    """Builds a `PkgsResult` from a decoded JSON dict.

    Walks the nested `versions_deps` map and reconstructs each `VersionDeps`
    struct.
    """
    d = d or {}
    versions_deps = {
        group: {
            version: _version_deps_from_dict(vd)
            for version, vd in per_version.items()
        }
        for group, per_version in d.get("versions_deps", {}).items()
    }
    return _pkgs_result_new(
        package_name_map = d.get("package_name_map", {}),
        versions_deps = versions_deps,
    )

deps_info = struct(
    new = _deps_info_new,
    from_dict = _deps_info_from_dict,
)

version_deps = struct(
    new = _version_deps_new,
    from_dict = _version_deps_from_dict,
)

target_deps = struct(
    new = _target_deps_new,
    qualify = _target_deps_qualify,
    from_dict = _target_deps_from_dict,
)

pkgs_result = struct(
    new = _pkgs_result_new,
    from_dict = _pkgs_result_from_dict,
)

schema = struct(
    KINDS = KINDS,
    DepsInfo = deps_info,
    VersionDeps = version_deps,
    TargetDeps = target_deps,
    PkgsResult = pkgs_result,
)
