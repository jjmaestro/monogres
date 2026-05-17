"""
Schema for `base`-layer data.

Defines:

- `BaseData`: the in-extension descriptor of the base hub state, built by
  `//monoext/private:base.bzl::create_base_src()` and consumed by
  `create_base()`. Does not cross a JSON boundary.
- `BaseSource`: per-version source labels (`dir`, `files`, `version`). Baked
  on each `BaseEntry` before the JSON boundary and rendered into the
  consumer-facing `CFG.sources` list.
- `BaseTarget`: one (version, option_set) target, encoded into
  `base_repo.entries`. Carries pre-qualified `artifact` + `source` labels along
  with `deps`.
- `BaseEntry`: per-base-version entry encoded into `base_repo.entries`.

`BaseSource`, `BaseTarget`, and `BaseEntry` cross the JSON boundary, so they
ship with `new`, `from_dict`, and (for `BaseEntry`) `decode` helpers. `BaseData`
is pure Starlark.
"""

load("//monoext/private:repo_names.bzl", "bind")
load("//monoext/private/pkgs:schema.bzl", _PkgsSchema = "schema")

def _base_data_new(
        pkgs_group,
        default_version,
        introspect_repos,
        introspect_paths_repos,
        metadata,
        source_repo,
        versions,
        flavor = "postgres"):
    """Constructs a `BaseData`.

    Args:
        pkgs_group: The base flavor's contribution to the shared deps pool
            (`struct(name, versions, metadata)`).
        default_version: Highest base version, used as default.
        introspect_repos: Dict `{pg_version: introspect_repo_name}` for Layer 2
            repos (full data with features + meson options). Keys retain the
            `pg_` prefix because introspect is currently PostgreSQL-specific.
        introspect_paths_repos: Dict `{pg_version: paths_repo_name}` for Layer 1
            repos (paths-only data from checked-in JSONs).
        metadata: Raw `metadata` block from `repo.json`.
        source_repo: Name of the `@{name}_src` source index repo.
        versions: Sorted list of all base versions from `repo.json`.
        flavor: Flavor identity from `metadata.flavor` (e.g. `"postgres"`,
            `"ivorysql"`). Drives build_options dispatch, the `pkgs_group` key,
            and the `CFG.name` baked into `all.bzl`.

    Returns:
        A `BaseData` struct.
    """
    return struct(
        pkgs_group = pkgs_group,
        default_version = default_version,
        introspect_repos = introspect_repos,
        introspect_paths_repos = introspect_paths_repos,
        metadata = metadata,
        source_repo = source_repo,
        versions = versions,
        flavor = flavor,
    )

def _base_source_init(dir, files, version):
    return struct(
        dir = dir,
        files = files,
        version = version,
    )

def _base_source_new(hub_name, version):
    """Constructs a `BaseSource`.

    Derives hub-rooted source labels from `hub_name` and `version`.

    Args:
        hub_name: Apparent name of the base hub repo.
        version: Base version string.

    Returns:
        A `BaseSource` struct.
    """
    f = bind(hub = hub_name, v = version)
    return _base_source_init(
        dir = f("@{hub}//{v}:dir"),
        files = f("@{hub}//{v}:files"),
        version = version,
    )

def _base_source_from_dict(d):
    """Builds a `BaseSource` from a decoded JSON dict."""
    return _base_source_init(
        dir = d["dir"],
        files = d["files"],
        version = d["version"],
    )

def _base_target_init(
        artifact,
        auto_features,
        build_options,
        deps,
        introspect,
        option_set,
        source,
        version):
    return struct(
        artifact = artifact,
        auto_features = auto_features,
        build_options = build_options,
        deps = deps,
        introspect = introspect,
        option_set = option_set,
        source = source,
        version = version,
    )

def _base_target_new(
        hub_name,
        version,
        option_set,
        auto_features,
        build_options,
        version_deps):
    """Constructs a `BaseTarget`.

    Derives hub-rooted artifact, introspect, deps, and source labels from the
    primitive inputs.

    Args:
        hub_name: Apparent name of the base hub repo.
        version: Base version string.
        option_set: Option set (e.g. `"regular"`, `"full"`).
        auto_features: Meson `--auto-features` value (`"enabled"` or
            `"disabled"`).
        build_options: Dict of Meson build options.
        version_deps: `VersionDeps` for this version, or `None`.

    Returns:
        A `BaseTarget` struct.
    """
    vd = version_deps if version_deps else _PkgsSchema.VersionDeps.new()
    f = bind(hub = hub_name, v = version, opt = option_set)
    return _base_target_init(
        artifact = f("@{hub}//{v}/{opt}:tar"),
        auto_features = auto_features,
        build_options = build_options,
        deps = _PkgsSchema.TargetDeps.qualify(f("@{hub}//{v}"), vd),
        introspect = f("@{hub}//{v}/{opt}:introspect"),
        option_set = option_set,
        source = _base_source_init(
            dir = f("@{hub}//{v}:dir"),
            files = f("@{hub}//{v}:files"),
            version = version,
        ),
        version = version,
    )

def _base_target_from_dict(d):
    """Builds a `BaseTarget` from a decoded JSON dict."""
    return _base_target_init(
        artifact = d["artifact"],
        auto_features = d["auto_features"],
        build_options = d["build_options"],
        deps = _PkgsSchema.TargetDeps.from_dict(d["deps"]),
        introspect = d["introspect"],
        option_set = d["option_set"],
        source = _base_source_from_dict(d["source"]),
        version = d["version"],
    )

def _base_entry_init(source_repo, source = None, targets = [], versions_deps = None):
    return struct(
        source = source,
        source_repo = source_repo,
        targets = targets,
        versions_deps = (
            versions_deps if versions_deps else _PkgsSchema.VersionDeps.new()
        ),
    )

def _base_entry_new(hub_name, version, source_repo, targets = [], versions_deps = None):
    """Constructs a `BaseEntry`.

    Derives the per-version `BaseSource` from `hub_name` and `version`. Takes
    pre-built targets (see `BaseTarget.new`).

    Note: `source_repo` is denormalized per-entry for wire-format convenience
    (also available as `base_repo.pg_src` at the repo level — the attribute
    keeps its `pg_` prefix because the introspect code path consumes it).

    Args:
        hub_name: Apparent name of the base hub repo.
        version: Base version string.
        source_repo: Name of the `@{name}_src` source index repo.
        targets: List of `BaseTarget` structs for this base version.
        versions_deps: `VersionDeps` for this version (or `None`).

    Returns:
        A `BaseEntry` struct.
    """
    f = bind(hub = hub_name, v = version)
    return _base_entry_init(
        source = _base_source_init(
            dir = f("@{hub}//{v}:dir"),
            files = f("@{hub}//{v}:files"),
            version = version,
        ),
        source_repo = source_repo,
        targets = targets,
        versions_deps = versions_deps,
    )

def _base_entry_from_dict(d):
    """Builds a `BaseEntry` from a decoded JSON dict."""
    raw_source = d.get("source")
    return _base_entry_init(
        source = _base_source_from_dict(raw_source) if raw_source else None,
        source_repo = d["source_repo"],
        targets = [_base_target_from_dict(t) for t in d.get("targets", [])],
        versions_deps = _PkgsSchema.VersionDeps.from_dict(
            d.get("versions_deps"),
        ),
    )

def _base_entry_decode(json_str):
    """Decodes a JSON-encoded `BaseEntry` string into a struct."""
    return _base_entry_from_dict(json.decode(json_str))

base_data = struct(
    new = _base_data_new,
)

base_source = struct(
    new = _base_source_new,
    from_dict = _base_source_from_dict,
)

base_target = struct(
    new = _base_target_new,
    from_dict = _base_target_from_dict,
)

base_entry = struct(
    new = _base_entry_new,
    from_dict = _base_entry_from_dict,
    decode = _base_entry_decode,
)

schema = struct(
    BaseData = base_data,
    BaseSource = base_source,
    BaseTarget = base_target,
    BaseEntry = base_entry,
)
