"""
Apt dependency resolution against a Debian snapshot.

In-process package resolution. Both the architecture list and the Debian
snapshot timestamp are passed by the caller as explicit args to `resolve(...)`
so the function carries no module-global state and any `ARCHS` source can be
plugged in.
"""

# buildifier: disable=bzl-visibility
load("@rules_distroless//apt/private:apt_deb_repository.bzl", "deb_repository")

# buildifier: disable=bzl-visibility
load(
    "@rules_distroless//apt/private:apt_dep_resolver.bzl",
    "dependency_resolver",
)

# buildifier: disable=bzl-visibility
load("@rules_distroless//apt/private:lockfile.bzl", "lockfile")

# buildifier: disable=bzl-visibility
load(
    "@rules_distroless//apt/private:version_constraint.bzl",
    "version_constraint",
)

_CODENAME = "stable"
_SNAPSHOT_URL = "https://snapshot-cloudflare.debian.org/archive"

def _sources_for(snapshot):
    """Build the apt sources tuple list for a given snapshot timestamp."""
    return [
        (
            ["%s/debian/%s" % (_SNAPSHOT_URL, snapshot)],
            _CODENAME,
            "main",
        ),
        (
            ["%s/debian-security/%s" % (_SNAPSHOT_URL, snapshot)],
            "%s-security" % _CODENAME,
            "main",
        ),
        (
            ["%s/debian/%s" % (_SNAPSHOT_URL, snapshot)],
            "%s-updates" % _CODENAME,
            "main",
        ),
    ]

def resolve(ctx, name, archs, packages, snapshot):
    """Resolves apt packages against a Debian snapshot.

    For each requested package and architecture, resolves the full transitive
    dependency closure and records any virtual package name substitutions.

    Args:
      ctx: The module extension context.
      name: The name of the generated repository.
      archs: List of Debian architecture strings to resolve (e.g. `["amd64",
          "arm64"]`). Caller-supplied so the resolver carries no module-global
          archs state.
      packages: List of package constraint strings.
      snapshot: Debian snapshot timestamp (e.g. `"20250113T000000Z"`).
          Caller-supplied so the resolver carries no module-global state.

    Returns:
      A tuple of (lockfile, package_name_map).
    """
    lockf = lockfile.empty(ctx)
    package_name_map = {}

    if not packages:
        return lockf, package_name_map

    repository = deb_repository.new(
        ctx,
        archs = archs,
        sources = _sources_for(snapshot),
    )
    resolver = dependency_resolver.new(repository)

    for arch in archs:
        seen = {}

        for dep_constraint in packages:
            if dep_constraint in seen:
                msg = "%s: duplicate package %r"
                fail(msg % (name, dep_constraint))

            seen[dep_constraint] = True
            constraint = version_constraint.parse_depends(dep_constraint).pop()

            package, dependencies, _ = resolver.resolve_all(
                arch = arch,
                include_transitive = True,
                name = constraint["name"],
                version = constraint["version"],
            )

            if not package:
                msg = "%s: unable to locate package %r for architecture %s"
                fail(msg % (name, dep_constraint, arch))

            resolved_name = package["Package"]
            requested_name = constraint["name"]

            if resolved_name != requested_name:
                package_name_map[requested_name] = resolved_name

            lockf.add_package(package, arch)

            for dep in dependencies:
                lockf.add_package(dep, arch)
                lockf.add_package_dependency(package, dep, arch)

    return lockf, package_name_map
