"""
Shared dependency package pool for `monoext`'s apt resolution.

Creates a single set of `deb_import` repos and one `deb_translate_lock` repo for
all package groups, eliminating package duplication across groups.

Wraps `@rules_distroless`'s private apt API intentionally:

  - the public `apt` module extension cannot be nested inside another module
    extension; using it would force callers to manually declare an additional
    root-level `use_extension(...)` / `use_repo(...)` flow.
  - the legacy `apt.install(...)` macro is WORKSPACE-oriented and incomplete
    by itself; its documented usage needs a second
    `load("@<repo>//:packages.bzl", "<repo>_packages")` followed by
    `<repo>_packages()` to create the per-package repos, which is not a clean
    fit for a module extension that needs one self-contained helper.

The resolver itself lives in the generic
`@sysroots//apt/private:apt_resolve.bzl`; this module is the `monoext`-specific
orchestration on top of that.
"""

# buildifier: disable=bzl-visibility
load("@rules_distroless//apt/private:deb_import.bzl", "deb_import")

# buildifier: disable=bzl-visibility
load(
    "@rules_distroless//apt/private:deb_translate_lock.bzl",
    "deb_translate_lock",
)

# buildifier: disable=bzl-visibility
load("@rules_distroless//apt/private:lockfile.bzl", "lockfile")

# buildifier: disable=bzl-visibility
load("@sysroots//apt/private:apt_resolve.bzl", "resolve")
load("//monoext/private/apt:apt_lock.bzl", _AptLock = "apt_lock")
load("//monoext/private/apt:schema.bzl", _AptSchema = "schema")
load("//monoext/private/apt:snapshot.bzl", "SNAPSHOT")
load("//platforms:targets.bzl", "ARCHS")

def apt_pkgs(ctx, name, package_groups, lock = None):
    """Creates a shared repo of Debian packages.

    Resolves ALL unique packages from all groups in a single pass and creates:
      - one `deb_import` per unique `(package, version, arch)`
      - one `deb_translate_lock` repo that organizes them

    When `lock` is provided, skips live resolution entirely and uses the cached
    lockfile data.

    Args:
        ctx: The module extension context.
        name: Internal lock repo name (e.g., `"pkgs_deb"`).
        package_groups: Dict of `{group_key: [packages]}`.
        lock: An `AptLock` struct, or `None` for live resolution.

    Returns:
        A tuple of `(AptResult, lock_json)` where `lock_json` is the JSON
        serialized `AptLock`.
    """
    if lock:
        packages = lock.packages
        package_name_map = lock.package_name_map
        lock_content = json.encode({
            "packages": lock.packages,
            "version": lock.version,
        })
    else:
        # live resolution
        packages = sorted(set([
            pkg
            for pkgs in package_groups.values()
            for pkg in pkgs
        ]))

        lockf, package_name_map = resolve(
            ctx,
            name,
            list(ARCHS),
            packages,
            SNAPSHOT,
        )

        packages = lockf.packages()
        lock_content = lockf.as_json()
        lock = _AptLock.new(
            snapshot = SNAPSHOT,
            archs = list(ARCHS),
            packages = packages,
            package_name_map = package_name_map,
        )

    for p in packages:
        key = lockfile.make_package_key(p["name"], p["version"], p["arch"])
        deb_import(
            name = "%s_%s" % (name, key),
            sha256 = p["sha256"],
            urls = p["urls"],
        )

    deb_translate_lock(name = name, lock_content = lock_content)

    apt_result = _AptSchema.AptResult.new(
        packages = packages,
        package_groups = package_groups,
        package_name_map = package_name_map,
    )

    return apt_result, _AptLock.encode(lock)
