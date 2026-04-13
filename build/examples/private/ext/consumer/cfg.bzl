"""
Downstream-style pgext consumer config.

With artifact + source labels baked into `@pg_ext//:all.bzl` `CFGS`, the
consumer shape IS the hub shape: `CFGS_CONSUMER = CFGS`. The load-time coherence
check below verifies each external cfg against its repo metadata (if metadata
says `deps.{kind}` are required, the corresponding `target.deps.{kind}.sysroot`
must be set, and vice-versa), keeping the "loading IS the contract test"
property from the previous three-phase pattern.
"""

load(
    "@pg_ext//:all.bzl",
    "EXTENSIONS",
    "KINDS",
    PGEXT_CFGS = "CFGS",
    PGEXT_REPOS = "REPOS",
)

def _has_deps(repo, kind, distro = "debian"):
    """Whether the repo metadata declares any `kind` deps for `distro`.

    The metadata stores deps as a `{spec: [pkgs]}` spec-map per distro; a
    non-empty spec-map means the extension has deps of that kind (the
    per-version resolution happens in `@pg_pkgs`).
    """
    deps = repo.metadata.get("deps", {})
    return bool(deps.get(kind, {}).get(distro, {}))

def _check_kind(name, target, kind, has_meta_deps):
    """Coherence check: metadata and target.deps agree on one kind."""
    kind_deps = getattr(target.deps, kind)
    has_target_sysroot = bool(kind_deps.sysroot)

    if has_meta_deps != has_target_sysroot:
        msg = "%s target %s/%s: metadata %s deps present=%s but target.deps.%s.sysroot is %r"
        fail(msg % (
            name,
            target.version,
            target.base_version.version,
            kind,
            has_meta_deps,
            kind,
            kind_deps.sysroot,
        ))

    # a populated sysroot must come with at least one package label (the two are
    # emitted together by the hub renderer).
    if has_target_sysroot and not kind_deps.packages:
        msg = "%s target %s/%s: target.deps.%s.sysroot is set but packages is empty"
        fail(msg % (name, target.version, target.base_version.version, kind))

def _check_target(name, repo, target):
    if not target.artifact:
        fail("%s target %s/%s: missing artifact label" % (
            name,
            target.version,
            target.base_version.version,
        ))

    if not target.source.dir or not target.source.files:
        fail("%s target %s/%s: missing source labels" % (
            name,
            target.version,
            target.base_version.version,
        ))

    for kind in KINDS:
        _check_kind(name, target, kind, _has_deps(repo, kind))

def _check_all(extensions, cfgs, repos):
    for ext_name in extensions:
        repo = repos[ext_name]
        for cfg in cfgs[ext_name]:
            for target in cfg.targets:
                _check_target(ext_name, repo, target)
    return cfgs, repos

CFGS, REPOS = _check_all(EXTENSIONS, PGEXT_CFGS, PGEXT_REPOS)
