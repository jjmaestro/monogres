"""
Schema for `monoext`'s apt-level data.

Defines the typed shapes (`AptGroup`, `AptResult`) produced by `apt_pkgs`.

These values do not currently cross a JSON boundary, but `from_dict` helpers are
provided for round-trip tests and to keep the serde layer uniform with the other
schema modules.
"""

def _apt_group_new(packages = [], resolved_names = []):
    """Constructs an `AptGroup` struct.

    Args:
        packages: Requested Debian package names for this group.
        resolved_names: Virtual → concrete resolved package names.

    Returns:
        An `AptGroup` struct.
    """
    return struct(
        packages = packages,
        resolved_names = resolved_names,
    )

def _apt_group_from_dict(d):
    """Builds an `AptGroup` from a decoded JSON dict."""
    d = d or {}
    return _apt_group_new(
        packages = d.get("packages", []),
        resolved_names = d.get("resolved_names", []),
    )

def _apt_result_new(packages = [], package_groups = {}, package_name_map = {}):
    """Constructs an `AptResult` struct from raw resolved data.

    Derives `deb_packages`, `groups`, and `pkg_info` from the inputs and keeps
    the input `packages` list verbatim under the `packages` field — downstream
    code (e.g. `//monoext/private/pkgs/closure.bzl`) needs the per-package
    `dependencies` field to walk the dep graph at module-extension time.

    Args:
        packages: List of resolved package dicts (each with `name`, `arch`,
            `version`, `dependencies` keys).
        package_groups: `{group_key: [requested_package_names]}`.
        package_name_map: `{requested_name: resolved_name}` for virtual package
            substitutions.

    Returns:
        An `AptResult` struct.
    """
    groups = {
        group_key: _apt_group_new(
            packages = pkgs,
            resolved_names = [
                package_name_map.get(pkg, pkg)
                for pkg in pkgs
            ],
        )
        for group_key, pkgs in package_groups.items()
    }

    pkg_info = {}
    for p in packages:
        if p["name"] not in pkg_info:
            pkg_info[p["name"]] = {}
        pkg_info[p["name"]][p["arch"]] = p["version"]

    return struct(
        package_name_map = package_name_map,
        deb_packages = sorted(set([p["name"] for p in packages])),
        groups = groups,
        packages = packages,
        pkg_info = pkg_info,
    )

def _apt_result_from_dict(d):
    """Builds an `AptResult` from a decoded JSON dict."""
    d = d or {}
    return struct(
        package_name_map = d.get("package_name_map", {}),
        deb_packages = d.get("deb_packages", []),
        groups = {
            k: _apt_group_from_dict(v)
            for k, v in d.get("groups", {}).items()
        },
        packages = d.get("packages", []),
        pkg_info = d.get("pkg_info", {}),
    )

apt_group = struct(
    new = _apt_group_new,
    from_dict = _apt_group_from_dict,
)

apt_result = struct(
    new = _apt_result_new,
    from_dict = _apt_result_from_dict,
)

schema = struct(
    AptGroup = apt_group,
    AptResult = apt_result,
)
