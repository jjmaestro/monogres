"""
Public API for the shared package hub repo layer.

This module runs in module extension context. It collects package groups from
all contributors (base flavor + extensions), resolves them via `apt_pkgs`, and
delegates hub file generation to the `pkgs_repo` repository rule in
`pkgs/hub.bzl`.

For each resolved package group, this module also instantiates one
`@sysroots//apt:apt_group(...)` sub-hub named `@pgbuildtime_<key>`. Each
per-group hub exposes:

  - `@pgbuildtime_<key>//debian/12/<arch>:sysroot` — `filegroup` over the
    extracted, normalized tree.
  - `@pgbuildtime_<key>//debian/12/<arch>:sysroot.tar` — single-file tar of
    the same tree (including files Bazel can't represent as target labels).

Buildtime consumers (`pg_build`, `pgxs_build`) take `:sysroot.tar` and extract
at action time via the shared setup script
(`monoext/private/base/sysroot_setup.sh`).
"""

load("@platform_debian//:versions.bzl", "RELEASE")
load("@sysroots//apt:apt_group.bzl", "apt_group")
load("@sysroots//common:stable_key.bzl", "stable_key")
load("@version_utils//version:version.bzl", Version = "version")
load("//monoext/private:repo_names.bzl", "bind", "repo_names")
load("//monoext/private/apt:apt_pkgs.bzl", "apt_pkgs")
load("//monoext/private/pkgs:collect.bzl", "collect_package_groups")
load("//monoext/private/pkgs:hub.bzl", "pkgs_repo")
load("//monoext/private/pkgs:schema.bzl", _PkgsSchema = "schema")
load("//platforms:targets.bzl", "ARCHS")

# Per-PG buildtime hubs materialize the active Debian release's sysroot. The
# distro is fixed; the release version comes from the profile.
_BUILDTIME_DISTRO = "debian"
_BUILDTIME_DISTRO_VERSION = RELEASE.version

def _group_labels(hub_name, group):
    """Builds @pkgs//deb/ labels for a resolved `AptGroup`."""
    labels = []
    for r in group.resolved_names:
        f = bind(hub = hub_name, pkg = r)
        labels.append(f("@{hub}//deb/{pkg}:{pkg}"))
    return labels

def pkgs_group(name, versions, metadata, version_scheme = Version.SCHEME.SEMVER):
    """Construct a pkgs group entry: the metadata contract for `create_pkgs`.

    Each group contributes one "thing" (e.g. the base flavor, or one extension)
    with a set of versions and a metadata dict from which deb deps are
    extracted.

    Args:
        name: Group name (used as key in the resolved `versions_deps`).
        versions: List of version strings for this group.
        metadata: Metadata dict with `deps.{build,run}time.debian.{spec:
            [pkgs]}`.
        version_scheme: A `Version.SCHEME` constant controlling how
            `metadata.deps.<kind>.debian.<spec>` keys parse `versions` strings.
            Defaults to `SEMVER` (extensions use 3-part `13.2.0`-style
            versions). Pass `PGVER` for the base flavor (PG-style 2-part `15.0`
            versions).

    Returns:
        A `struct` with `name`, `versions`, `metadata`, and `version_scheme`
        fields.
    """
    return struct(
        name = name,
        versions = versions,
        metadata = metadata,
        version_scheme = version_scheme,
    )

def create_pkgs(ctx, hub_name, groups, lock = None):
    """Creates the shared package repo and hub from a list of groups.

    Encapsulates the full `@{hub_name}` lifecycle: collect package groups from
    all contributors, resolve packages, compute sysroot groups, generate the hub
    repo, and map resolved deps back to each group version.

    NOTE: without a lockfile, this function downloads 3 Debian snapshot sources
    x 2 architectures = 6 Package index files from
    snapshot-cloudflare.debian.org on every cold evaluation.  The `deb_lock`
    attr on the monogres tag provides a lockfile that eliminates these downloads
    entirely.  See `//apt:apt_lock.bzl`.

    Args:
        ctx: The module extension context.
        hub_name: Hub repo name (e.g. `"pg_pkgs"`).
        groups: List of `pkgs_group` structs.
        lock: A lock data struct from `apt_lock.bzl`, or `None` for live
            resolution (with a warning).

    Returns:
        A `PkgsResult` struct.
    """
    if not lock:
        # buildifier: disable=print
        print((
            "WARNING: No apt lockfile for '%s'. Resolving live " +
            "(downloading 6 Debian Package indices).\n" +
            "To generate a lockfile, run:\n" +
            "    bazel run @%s//deb/lock:update\n" +
            "Then add to your monogres tag:\n" +
            '    deb_lock = "//catalog/locks:%s.lock"'
        ) % (hub_name, hub_name, hub_name))

    entries = {
        g.name: {
            "ext_versions": g.versions,
            "metadata": g.metadata,
            "version_scheme": g.version_scheme,
        }
        for g in groups
    }

    pkgs_groups, ext_dep_groups = collect_package_groups(
        entries,
        RELEASE.version,
    )

    deb_repo = repo_names.deb_repo(hub_name)
    apt_result, lock_json = apt_pkgs(ctx, deb_repo, pkgs_groups, lock)

    # Build `group_dep_info` and, in parallel, instantiate one
    # `@sysroots//apt:hub_repo` per resolved package group. Each per-group hub
    # produces `@pgbuildtime_<key>//debian/12/<arch>:sysroot` filegroups that
    # `pg_build` consumes via the per-target alias rendered in `versions.bzl`.
    group_dep_info = {}

    for group_key, group in apt_result.groups.items():
        labels = _group_labels(hub_name, group)

        # `stable_key` over the per-package labels yields a content-keyed,
        # order-independent hub name: two `AptGroup`s with the same resolved
        # label set produce the same `@pgbuildtime_<key>` name and share a
        # single materialized hub.
        hub_repo_name = stable_key(labels, prefix = "pgbuildtime")
        sysroot_labels_by_arch = {
            arch: "@%s//%s/%s/%s:sysroot" % (
                hub_repo_name,
                _BUILDTIME_DISTRO,
                _BUILDTIME_DISTRO_VERSION,
                arch,
            )
            for arch in ARCHS
        }
        sysroot_tar_labels_by_arch = {
            arch: "@%s//%s/%s/%s:sysroot.tar" % (
                hub_repo_name,
                _BUILDTIME_DISTRO,
                _BUILDTIME_DISTRO_VERSION,
                arch,
            )
            for arch in ARCHS
        }

        group_dep_info[group_key] = _PkgsSchema.DepsInfo.new(
            packages = group.packages,
            pkgs_labels = labels,
            sysroot_labels_by_arch = sysroot_labels_by_arch,
            sysroot_tar_labels_by_arch = sysroot_tar_labels_by_arch,
        )

        apt_group(
            name = hub_repo_name,
            distro = _BUILDTIME_DISTRO,
            version = _BUILDTIME_DISTRO_VERSION,
            packages = apt_result.packages,
            requested_names = group.resolved_names,
        )

    pkgs_repo(
        name = hub_name,
        deb_repo = deb_repo,
        deb_packages = apt_result.deb_packages,
        pkg_info = apt_result.pkg_info,
        lock_json = lock_json,
        lock_path = "catalog/locks/%s.lock" % hub_name,
    )

    # map group dep info back to per-group versions_deps
    versions_deps = {}
    for name, entry in entries.items():
        vd = {}
        for version in entry["ext_versions"]:
            vd[version] = _PkgsSchema.VersionDeps.new(
                buildtime = group_dep_info.get(
                    ext_dep_groups.get("buildtime", {}).get((name, version)),
                ),
                runtime = group_dep_info.get(
                    ext_dep_groups.get("runtime", {}).get((name, version)),
                ),
            )
        versions_deps[name] = vd

    return _PkgsSchema.PkgsResult.new(
        package_name_map = apt_result.package_name_map,
        versions_deps = versions_deps,
    )

testing = struct(
    _group_labels = _group_labels,
)
