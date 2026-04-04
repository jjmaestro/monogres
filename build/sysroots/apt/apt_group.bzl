"""
Public helper for materializing one apt hub repo from a shared resolver pool.

Complements the declarative `sysroots.apt(...)` tag with an imperative path for
callers that fan a single resolved package list into many per-group sub-hubs
(one hub per dep group, dedup-by-content via a stable name).

The caller owns:

  - resolving the shared package pool, e.g. via the resolver in
    `//apt/private:apt_resolve.bzl`.
  - choosing a stable hub name, e.g. via `//common:stable_key.bzl`.
  - choosing the seed names whose transitive closure scopes each
    sub-hub.

`apt_group` walks the closure (via `//apt/private:closure.bzl`), shapes the
`distros_json` payload, and instantiates one `hub_repo`. The lockfile lives
upstream in the shared pool, so each sub-hub skips the `lock/` subpackage.
"""

# buildifier: disable=bzl-visibility
load("//apt/private:closure.bzl", "closure")

# buildifier: disable=bzl-visibility
load("//apt/private:repo.bzl", "hub_repo")

def apt_group(
        name,
        distro,
        version,
        packages,
        requested_names,
        extra_files = {}):
    """Materialize one apt hub repo scoped to a seed's transitive closure.

    Args:
        name: Hub repo name.
        distro: Distro id (e.g. `"debian"`).
        version: Distro version (e.g. `"12"`).
        packages: Flat list of resolved package dicts from a shared resolver
            pool, each carrying `name`, `arch`, and `dependencies` fields.
        requested_names: Directly-requested resolved names that seed each
            per-arch transitive closure.
        extra_files: Tier-2 file injection map passed through to `hub_repo`:
            `{source_label: in_sysroot_path}`. The path may contain a `{arch}`
            placeholder substituted at write time. Defaults to no injection.

    Returns:
        None. The hub repo is instantiated as a side effect; its per-arch
        `:sysroot` filegroups and `:sysroot.tar` artifacts are reachable at
        `@<name>//<distro>/<version>/<arch>:sysroot[.tar]`.
    """
    closures = closure.transitive_closure_by_arch(packages, requested_names)

    info = {
        "archs": closures,
        "lock_filename": "",
        "lock_json": "",
        "lock_path": "",
    }

    distros_json = json.encode({distro: {version: info}})

    hub_repo(
        name = name,
        distros_json = distros_json,
        extra_files = extra_files,
    )
