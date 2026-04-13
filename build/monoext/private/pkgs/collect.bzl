"""
Collect package groups from extension metadata.

Pure function that takes data (not `ctx`), making it unit-testable. Used by the
`@pkgs` layer to build globally-deduplicated package groups.
"""

load("@version_utils//version:version.bzl", Version = "version")
load(":schema.bzl", _PkgsSchema = "schema")
load(":version_deps.bzl", "get_version_deps")

def _deps(metadata, kind, debian_version, distro = "debian"):
    """Extracts the deps spec map for a Debian release from metadata.

    The `deps.<kind>.<distro>` map is keyed first by Debian release version
    (e.g. `"12"`), then by the PG-version spec. Returns the spec map for
    `debian_version`, or `{}` when the release is absent (resolving to no
    packages, which gates the extension out of that release).
    """
    specs = metadata.get("deps", {}).get(kind, {}).get(distro, {})
    return specs.get(debian_version, {})

def collect_package_groups(extensions, debian_version):
    """Collects globally-deduplicated package groups from extensions.

    Iterates all extensions and their version-resolved deps, building a
    content-addressed map of unique package sets and a nested mapping from kind
    to `(ext_name, ext_version)` to group keys.

    Args:
        extensions: Dict of `{name: {ext_versions, metadata}}`.
        debian_version: Debian release version key (e.g. `"12"`) selecting the
            per-release deps spec map to resolve against.

    Returns:
        Tuple of `(pkgs_groups, ext_dep_groups)` where:
          - `pkgs_groups`: `{content_key: [packages]}`
          - `ext_dep_groups`:
            `{kind: {(name, version): content_key}}`
    """
    pkgs_groups = {}
    ext_dep_groups = {}

    for name, ext in sorted(extensions.items()):
        # `version_scheme` is set by `pkgs_group` (defaults to SEMVER for the
        # extension layer; the base layer overrides to PGVER so PG-style
        # `15.0`-shaped versions parse correctly under the
        # `metadata.deps.<kind>.debian.<spec>` map). Default to SEMVER for test
        # fixtures and callers that pre-date the `version_scheme` field.
        version_scheme = ext.get("version_scheme", Version.SCHEME.SEMVER)
        for kind in _PkgsSchema.KINDS:
            deps = _deps(ext["metadata"], kind, debian_version)

            for ext_version in ext["ext_versions"]:
                packages = get_version_deps(
                    ext_version,
                    deps,
                    version_scheme = version_scheme,
                )

                if packages:
                    key = ",".join(sorted(packages))
                    pkgs_groups[key] = packages

                    if kind not in ext_dep_groups:
                        ext_dep_groups[kind] = {}

                    ext_dep_groups[kind][(name, ext_version)] = key

    return pkgs_groups, ext_dep_groups
