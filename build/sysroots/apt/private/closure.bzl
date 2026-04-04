"""
Transitive closure walker over apt lockfile dependency edges.

Given a flat lockfile-shaped list of resolved packages (each carrying `name`,
`arch`, and `dependencies` fields) plus a list of directly-requested resolved
names, produces the minimal per-arch package list covering every package
reachable through `dependencies`.

Useful when materializing a sub-hub scoped to a subset of a shared apt resolver
pool: the walker bounds the sub-hub's `.deb` download set to what its seed names
actually need, without re-resolving against the snapshot.
"""

# Bound for the fixed-point loop. The dependency DAG depth is shallow in
# practice (depth ~10 for `libc6` + its transitives), so 100 iterations is
# comfortably above the worst case. Higher than necessary is harmless; the loop
# exits as soon as one pass adds no new names.
_MAX_CLOSURE_ITERATIONS = 100

def _index_by_arch(packages):
    """Group resolved packages by arch, indexed by `name` for O(1) lookup.

    Args:
        packages: Flat list of package dicts, each carrying `name`, `arch`, and
            `dependencies` fields.

    Returns:
        Dict of `{arch: {name: package_dict}}`.
    """
    by_arch = {}
    for pkg in packages:
        arch = pkg["arch"]
        bucket = by_arch.get(arch)
        if bucket == None:
            bucket = {}
            by_arch[arch] = bucket
        bucket[pkg["name"]] = pkg
    return by_arch

def _closure_for_arch(by_name, requested_names):
    """Fixed-point BFS over `dependencies` edges starting from requested names.

    Names that don't exist in `by_name` are silently skipped; happens when a
    lockfile's `package_name_map` rewrote a virtual name and the seed list still
    references the virtual entry (defensive; callers should pass post-mapping
    names).

    Args:
        by_name: `{name: package_dict}` for one arch.
        requested_names: Direct names that seed the walk.

    Returns:
        List of package dicts in `by_name`, sorted by name, covering the full
        reachable closure.
    """
    seen = {}
    for name in requested_names:
        seen[name] = True

    for _ in range(_MAX_CLOSURE_ITERATIONS):
        new_names = []
        for name in seen.keys():
            pkg = by_name.get(name)
            if pkg == None:
                continue
            for dep in pkg.get("dependencies", []):
                if dep["name"] not in seen:
                    new_names.append(dep["name"])
        if not new_names:
            break
        for name in new_names:
            seen[name] = True

    return [
        by_name[name]
        for name in sorted(seen.keys())
        if name in by_name
    ]

def _transitive_closure_by_arch(packages, requested_names):
    """Compute per-arch transitive closures over a flat lockfile package list.

    Args:
        packages: Flat list of package dicts, each carrying `name`, `arch`, and
            `dependencies` fields.
        requested_names: Directly-requested resolved package names that seed
            each per-arch walk.

    Returns:
        `{arch: [package_dict, ...]}`, full transitive closure per arch.
    """
    by_arch = _index_by_arch(packages)
    return {
        arch: _closure_for_arch(by_name, requested_names)
        for arch, by_name in by_arch.items()
    }

closure = struct(
    transitive_closure_by_arch = _transitive_closure_by_arch,
)

testing = struct(
    _index_by_arch = _index_by_arch,
    _closure_for_arch = _closure_for_arch,
)
