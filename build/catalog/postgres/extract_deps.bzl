"""
Per-version Debian buildtime/runtime package extraction from `repo.json`.

A small focused helper that decodes `repo.json` and returns `{pg_version:
{buildtime: [packages], runtime: [packages]}}`. Phase 3 onward uses this to
drive `sysroots.apt(...)` tag declarations per Postgres version without going
through the monoext spec-matching layer.

Today the only spec key in `catalog/postgres/repo.json` is `"*"` (matches every
version), so this helper supports that wildcard only. When per-version or
per-arch specs appear in the JSON, this helper will need to delegate to
`//monoext/private/pkgs:version_deps.bzl::spec_matches` or grow its own
equivalent; until then keeping the matching trivial avoids re-implementing the
fuller logic at two call sites.
"""

load("@version_utils//spec:spec.bzl", Spec = "spec")
load("@version_utils//version:version.bzl", Version = "version")

_KINDS = ("buildtime", "runtime")

def _spec_matches(spec_str, version):
    """Match a `metadata.deps.<kind>.debian.<spec>` key against a pg version.

    Supports `"*"` (matches every version) and plain version-range specs (e.g.
    `">=17"`, `"<16,>=15"`). The `/arch` suffix is not handled — that requires
    the per-arch group machinery in `//monoext/private/pkgs`.

    Args:
        spec_str: Spec key from `repo.json`.
        version: Postgres version string (e.g. `"18.1"`).

    Returns:
        True when the spec applies.
    """
    if spec_str == "*":
        return True
    if "/" in spec_str:
        fail((
            "extract_deps: spec %r has a `/arch` suffix; this simple helper " +
            "only supports plain version specs. Use the //monoext per-arch " +
            "machinery for arch-specific deps."
        ) % spec_str)
    return Spec.new(
        spec_str,
        version_scheme = Version.SCHEME.PGVER,
    ).match(version)

def _packages_for_version(spec_dict, version):
    """Collect all packages whose spec matches `version`, deduped + sorted."""
    seen = {}
    for spec_str, pkgs in spec_dict.items():
        if _spec_matches(spec_str, version):
            for pkg in pkgs:
                seen[pkg] = True
    return sorted(seen.keys())

def extract_deps(repo_json_str):
    """Decode a Postgres `repo.json` and return per-version Debian deps.

    Args:
        repo_json_str: Content of `//catalog/postgres:repo.json` as a string
            (typically from `ctx.read(label)`).

    Returns:
        Dict `{pg_version: {"buildtime": [packages], "runtime": [packages]}}`
        with every Postgres version in `repo.json` populated. Packages are
        sorted and deduplicated.
    """
    data = json.decode(repo_json_str)
    versions = data.get("versions", {}).keys()
    deps = data.get("deps", {})

    result = {}
    for version in versions:
        result[version] = {}
        for kind in _KINDS:
            spec_dict = deps.get(kind, {}).get("debian", {})
            result[version][kind] = _packages_for_version(spec_dict, version)
    return result
