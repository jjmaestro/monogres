"""
Schema for `ext`-layer data.

Defines:

- `ExtData`: in-extension descriptor of the extensions hub state, built by
  `//monoext/private:ext.bzl::create_ext_src()`. Does not cross a JSON boundary.
- `ExtensionEntry`: one extension's in-extension metadata (before entries are
  encoded for the hub repo rule). Does not cross JSON.
- `ExtSource`: per-ext-version source labels (`dir`, `files`, `version`).
  Baked on external entries before the JSON boundary.
- `ExtExternalTarget`: one (ext_version × base_version) external target with
  pre-qualified `artifact`, `deps`, `base_version`, `source`, `version`.
- `ExtContribTarget`: one (contrib × base_version) target with pre-qualified
  `artifact` + `base_version`. Contribs have no own `deps` or `source`.
- `ExtExternalEntry`: per-external-extension entry encoded into
  `ext_repo.entries`. Carries pre-expanded `targets` + `sources`. Crosses JSON.
- `ExtContribEntry`: per-contrib entry encoded into `ext_repo.entries`.
  Carries pre-expanded `targets`. Crosses JSON.

`ExtExternalEntry` has no `.decode()` sugar because its `lock` field is merged
into the decoded dict (from `rctx.read(locks[name])`) before the struct is
constructed; see `ext/hub.bzl::_impl()`.
"""

load("//monoext/private:repo_names.bzl", "bind")
load("//monoext/private/pkgs:schema.bzl", _PkgsSchema = "schema")

def _ext_data_new(pkgs_groups = [], extensions = {}, pgrx_crates = {}):
    """Constructs an `ExtData`.

    Args:
        pkgs_groups: List of `pkgs_group` structs (non-contribs only; contribs
            have no external deb deps).
        extensions: `{ext_name: ExtensionEntry}` dict.
        pgrx_crates: `{pgrx_version: {package: dir_name}}`, the crate pool repos
            backing one pgrx SQL generator per pgrx version the catalog's
            extensions pin. Empty when no extension declares `build_system`
            `"pgrx"`, in which case no generator is built at all.

    Returns:
        A `struct(pkgs_groups, extensions, pgrx_crates)`.
    """
    return struct(
        pkgs_groups = pkgs_groups,
        extensions = extensions,
        pgrx_crates = pgrx_crates,
    )

def _extension_entry_new(
        ext_versions,
        is_contrib,
        metadata,
        source_repo = None,
        lock = None,
        introspect_versions = [],
        build_data = {},
        cargo = {}):
    """Constructs an `ExtensionEntry`.

    Args:
        ext_versions: Sorted list of extension version strings.
        is_contrib: `True` for contrib extensions, `False` for external.
        metadata: Raw `metadata` block from the extension's `repo.json`.
        source_repo: Source repo name for external extensions
            (`{name}_src__{ext}`), or `None` for contrib.
        lock: Label of the external extension's lockfile (a string like
            `"@pg_ext_src--citus//:lock.json"`), or `None` for contrib.
        introspect_versions: Sorted list of the ext versions that ship a
            committed test introspect (`introspect/<ext>~<ver>.json`); drives
            the regen + freshness manifest. Empty for contrib and for external
            extensions not yet migrated onto discovery.
        build_data: `{"files": {path: label}, "env": {var: directory}}`: the
            files this extension's build stages instead of downloading, and the
            variables pointing a fetching build step at them. Empty unless the
            extension declares `metadata.build_data`.
        cargo: `{ext_version: {"lock": label, "crates": {package: dir},
            "git_sources": {source: {key: value}}, "pgrx": version}}` for a pgrx
            extension: the catalog `Cargo.lock` its closure was read from, the
                crate pool packages that closure resolved to, the cargo source
                replacement its git dependencies need (empty without any), and
                the pgrx version the lock pins (which selects the SQL
                generator). Empty for contrib and for every other build system.

    Returns:
        An `ExtensionEntry` struct.
    """
    return struct(
        ext_versions = ext_versions,
        is_contrib = is_contrib,
        metadata = metadata,
        source_repo = source_repo,
        lock = lock,
        introspect_versions = introspect_versions,
        build_data = build_data,
        cargo = cargo,
    )

def _ext_source_init(dir, files, version):
    return struct(
        dir = dir,
        files = files,
        version = version,
    )

def _ext_source_new(ext_hub_name, ext_name, ext_version):
    """Constructs an `ExtSource`.

    Derives hub-rooted source labels from the primitive inputs.

    Args:
        ext_hub_name: Apparent name of the extensions hub repo.
        ext_name: Extension name.
        ext_version: Extension version string.

    Returns:
        A `struct(dir, files, version)`.
    """
    f = bind(hub = ext_hub_name, ext = ext_name, ext_v = ext_version)
    return _ext_source_init(
        dir = f("@{hub}//{ext}/{ext_v}:dir"),
        files = f("@{hub}//{ext}/{ext_v}:files"),
        version = ext_version,
    )

def _ext_source_from_dict(d):
    """Builds an `ExtSource` from a decoded JSON dict."""
    return _ext_source_init(
        dir = d["dir"],
        files = d["files"],
        version = d["version"],
    )

def _base_version_struct(base_v, flavor = "postgres"):
    """Synthesizes the `base_version = struct(name, version)` baked on targets."""
    return struct(name = "%s~%s" % (flavor, base_v), version = base_v)

def _base_version_from_dict(d):
    return struct(name = d["name"], version = d["version"])

def _ext_external_target_init(artifact, deps, base_version, source, version):
    return struct(
        artifact = artifact,
        deps = deps,
        base_version = base_version,
        source = source,
        version = version,
    )

def _ext_external_target_new(
        ext_hub_name,
        ext_name,
        ext_version,
        base_v,
        version_deps,
        flavor = "postgres"):
    """Constructs an `ExtExternalTarget`.

    Derives artifact, base_version, deps, and source from primitive inputs.

    Args:
        ext_hub_name: Apparent name of the extensions hub repo.
        ext_name: Extension name.
        ext_version: Extension version string.
        base_v: Base version string.
        version_deps: `VersionDeps` for this ext_version, or `None`.
        flavor: Base flavor identity (e.g. "postgres", "ivorysql").

    Returns:
        An `ExtExternalTarget` struct.
    """
    vd = version_deps if version_deps else _PkgsSchema.VersionDeps.new()
    f = bind(
        hub = ext_hub_name,
        ext = ext_name,
        ext_v = ext_version,
        base_v = base_v,
    )
    return _ext_external_target_init(
        artifact = f("@{hub}//{ext}/{ext_v}/{base_v}:{base_v}"),
        deps = _PkgsSchema.TargetDeps.qualify(f("@{hub}//{ext}/{ext_v}"), vd),
        base_version = _base_version_struct(base_v, flavor = flavor),
        source = _ext_source_init(
            dir = f("@{hub}//{ext}/{ext_v}:dir"),
            files = f("@{hub}//{ext}/{ext_v}:files"),
            version = ext_version,
        ),
        version = ext_version,
    )

def _ext_external_target_from_dict(d):
    return _ext_external_target_init(
        artifact = d["artifact"],
        deps = _PkgsSchema.TargetDeps.from_dict(d["deps"]),
        base_version = _base_version_from_dict(d["base_version"]),
        source = _ext_source_from_dict(d["source"]),
        version = d["version"],
    )

def _ext_contrib_target_init(artifact, base_version):
    return struct(
        artifact = artifact,
        base_version = base_version,
    )

def _ext_contrib_target_new(ext_hub_name, ext_name, base_v, flavor = "postgres"):
    """Constructs an `ExtContribTarget`.

    Derives artifact and base_version from primitive inputs. Contribs have no
    own `deps` or `source` (they inherit from PG).

    Args:
        ext_hub_name: Apparent name of the extensions hub repo.
        ext_name: Contrib extension name.
        base_v: Base version string.
        flavor: Base flavor identity (e.g. "postgres", "ivorysql").

    Returns:
        A `struct(artifact, base_version)`.
    """
    f = bind(hub = ext_hub_name, name = ext_name, base_v = base_v)
    return _ext_contrib_target_init(
        artifact = f("@{hub}//contrib/{name}/{base_v}:tar"),
        base_version = _base_version_struct(base_v, flavor = flavor),
    )

def _ext_contrib_target_from_dict(d):
    return _ext_contrib_target_init(
        artifact = d["artifact"],
        base_version = _base_version_from_dict(d["base_version"]),
    )

def _ext_external_entry_init(
        name,
        deps,
        versions_deps,
        compatible_base_versions,
        source_repo,
        sources = [],
        targets = [],
        lock = None,
        build_system = "pgxs",
        build_args = [],
        remap_paths = {},
        crate_dir = "",
        build_data = {},
        cargo = {}):
    """Raw initializer for external entries; sets `is_contrib = False`.

    `cargo` is `{ext_version: {"lock": label, "crates": {package: dir},
    "git_sources": {source: {key: value}}, "pgrx": version}}` for a `"pgrx"`
    extension: the catalog `Cargo.lock` the build is held to, the crate pool
    packages its closure resolved to, the cargo source replacement its git
    dependencies need, and the pgrx version it pins (which selects the SQL
    generator). Empty for every other build system.

    `build_system` selects the build rule the hub renders for this extension
    (`"pgxs"`, the default, `"cmake"` or `"pgrx"`). `build_args` is the list of
    extra build flags (PGXS/autoconf `configure` args, or CMake `-D` cache
    entries), templated with `{pg_config}` / `{sysroot}` resolved to action-time
    sysroot paths by the build rule. `remap_paths` is a `{file: {from: to}}` map
    whose `from`->`to` substitutions the build applies to the sysroot's
    `usr/bin/<file>` scripts (re-rooting baked paths a build step reads
    verbatim). `crate_dir` (the pgrx path only) is the extension crate's
    directory below the source root, for a cargo WORKSPACE whose root has to
    stay the source root so path dependencies and the workspace profile resolve;
    empty means the crate IS the source root. All come from the extension's
    `repo.json` `metadata` and are extension-wide (not per-version).
    """
    return struct(
        name = name,
        deps = deps,
        versions_deps = versions_deps,
        compatible_base_versions = compatible_base_versions,
        source_repo = source_repo,
        sources = sources,
        targets = targets,
        lock = lock,
        is_contrib = False,
        build_system = build_system,
        build_args = build_args,
        remap_paths = remap_paths,
        crate_dir = crate_dir,
        build_data = build_data,
        cargo = cargo,
    )

def _ext_external_entry_new(
        ext_hub_name,
        ext_name,
        ext_versions,
        compatible_base_versions,
        source_repo,
        ext_versions_deps,
        lock = None,
        base_flavor = "postgres",
        build_system = "pgxs",
        build_args = [],
        remap_paths = {},
        crate_dir = "",
        build_data = {},
        cargo = {}):
    """Constructs an `ExtExternalEntry`.

    Derives deps, sources, and targets from primitive inputs. The
    `compatible_base_versions` map is computed by the caller (domain logic).

    Args:
        ext_hub_name: Apparent name of the extensions hub repo.
        ext_name: Extension name.
        ext_versions: Sorted list of extension version strings.
        compatible_base_versions: `{ext_version: [base_version, ...]}` with the
            base versions each extension version is compatible with.
        source_repo: Source repo name (`{name}_src__{ext}`).
        ext_versions_deps: `{ext_version: VersionDeps}` from the shared deps
            pool.
        lock: Decoded lockfile contents, or `None` (default at encode time).
        base_flavor: Base flavor identity (e.g. "postgres", "ivorysql").
        build_system: Build rule selector (`"pgxs"` default, `"cmake"` or
            `"pgrx"`).
        build_args: Extra build flags (autoconf/PGXS `configure` args, CMake
            `-D` cache entries or `cargo build` arguments), templated to sysroot
            paths by the build rule.
        remap_paths: `{file: {from: to}}` substitutions the build applies to the
            sysroot's `usr/bin/<file>` scripts.
        crate_dir: The pgrx extension crate's directory below the source root,
            for a cargo workspace; empty when the crate is the source root.
        build_data: `{"files": {path: label}, "env": {var: directory}}` the
            build stages instead of letting a build step download it; empty
            unless declared.
        cargo: `{ext_version: {"lock": label, "crates": {package: dir},
            "git_sources": {source: {key: value}}, "pgrx": version}}` for a pgrx
            extension; empty otherwise.

    Returns:
        An `ExtExternalEntry` struct.
    """
    deps = {}
    for ext_v in ext_versions:
        f = bind(hub = ext_hub_name, ext = ext_name, ext_v = ext_v)
        deps[ext_v] = _PkgsSchema.TargetDeps.qualify(
            f("@{hub}//{ext}/{ext_v}"),
            ext_versions_deps.get(ext_v),
        )

    sources_by_version = {}
    for ext_v in ext_versions:
        f = bind(hub = ext_hub_name, ext = ext_name, ext_v = ext_v)
        sources_by_version[ext_v] = _ext_source_init(
            dir = f("@{hub}//{ext}/{ext_v}:dir"),
            files = f("@{hub}//{ext}/{ext_v}:files"),
            version = ext_v,
        )

    targets = []
    for ext_v in sorted(ext_versions):
        for base_v in sorted(compatible_base_versions.get(ext_v, [])):
            f = bind(
                hub = ext_hub_name,
                ext = ext_name,
                ext_v = ext_v,
                base_v = base_v,
            )
            targets.append(_ext_external_target_init(
                artifact = f("@{hub}//{ext}/{ext_v}/{base_v}:{base_v}"),
                deps = deps[ext_v],
                base_version = _base_version_struct(
                    base_v,
                    flavor = base_flavor,
                ),
                source = sources_by_version[ext_v],
                version = ext_v,
            ))
    return _ext_external_entry_init(
        name = ext_name,
        deps = deps,
        versions_deps = ext_versions_deps,
        compatible_base_versions = compatible_base_versions,
        source_repo = source_repo,
        sources = [sources_by_version[v] for v in sorted(ext_versions)],
        targets = targets,
        lock = lock,
        build_system = build_system,
        build_args = build_args,
        remap_paths = remap_paths,
        crate_dir = crate_dir,
        build_data = build_data,
        cargo = cargo,
    )

def _ext_external_entry_from_dict(d):
    """Builds an `ExtExternalEntry` from a decoded JSON dict.

    The `lock` field must be merged into `d` by the caller before this is
    invoked; see `ext/hub.bzl::_impl()`.
    """
    return _ext_external_entry_init(
        name = d["name"],
        deps = {
            ext_v: _PkgsSchema.TargetDeps.from_dict(raw)
            for ext_v, raw in d["deps"].items()
        },
        versions_deps = {
            version: _PkgsSchema.VersionDeps.from_dict(vd)
            for version, vd in d["versions_deps"].items()
        },
        compatible_base_versions = d["compatible_base_versions"],
        source_repo = d["source_repo"],
        sources = [_ext_source_from_dict(s) for s in d.get("sources", [])],
        targets = [
            _ext_external_target_from_dict(t)
            for t in d.get("targets", [])
        ],
        lock = d.get("lock"),
        build_system = d.get("build_system", "pgxs"),
        build_args = d.get("build_args", []),
        remap_paths = d.get("remap_paths", {}),
        crate_dir = d.get("crate_dir", ""),
        build_data = d.get("build_data", {}),
        cargo = d.get("cargo", {}),
    )

def _ext_contrib_entry_init(ext_versions, metadata, name, targets = []):
    """Raw initializer for contrib entries; sets `is_contrib = True`."""
    return struct(
        ext_versions = ext_versions,
        is_contrib = True,
        metadata = metadata,
        name = name,
        targets = targets,
    )

def _ext_contrib_entry_new(
        ext_hub_name,
        ext_name,
        ext_versions,
        metadata,
        base_flavor = "postgres"):
    """Constructs an `ExtContribEntry`.

    Derives targets from primitive inputs.

    Args:
        ext_hub_name: Apparent name of the extensions hub repo.
        ext_name: Contrib extension name.
        ext_versions: Sorted list of base version strings the contrib ships for.
        metadata: Raw contrib `metadata` block.
        base_flavor: Base flavor identity (e.g. "postgres", "ivorysql").

    Returns:
        An `ExtContribEntry` struct.
    """
    targets = []
    for base_v in sorted(ext_versions):
        f = bind(hub = ext_hub_name, name = ext_name, base_v = base_v)
        targets.append(_ext_contrib_target_init(
            artifact = f("@{hub}//contrib/{name}/{base_v}:tar"),
            base_version = _base_version_struct(base_v, flavor = base_flavor),
        ))
    return _ext_contrib_entry_init(
        ext_versions = ext_versions,
        metadata = metadata,
        name = ext_name,
        targets = targets,
    )

def _ext_contrib_entry_from_dict(d):
    """Builds an `ExtContribEntry` from a decoded JSON dict."""
    return _ext_contrib_entry_init(
        ext_versions = d["ext_versions"],
        metadata = d["metadata"],
        name = d["name"],
        targets = [
            _ext_contrib_target_from_dict(t)
            for t in d.get("targets", [])
        ],
    )

def _ext_contrib_entry_decode(json_str):
    """Decodes a JSON-encoded `ExtContribEntry` string into a struct."""
    return _ext_contrib_entry_from_dict(json.decode(json_str))

ext_data = struct(
    new = _ext_data_new,
)

extension_entry = struct(
    new = _extension_entry_new,
)

ext_source = struct(
    new = _ext_source_new,
    from_dict = _ext_source_from_dict,
)

ext_external_target = struct(
    new = _ext_external_target_new,
    from_dict = _ext_external_target_from_dict,
)

ext_contrib_target = struct(
    new = _ext_contrib_target_new,
    from_dict = _ext_contrib_target_from_dict,
)

ext_external_entry = struct(
    new = _ext_external_entry_new,
    from_dict = _ext_external_entry_from_dict,
)

ext_contrib_entry = struct(
    new = _ext_contrib_entry_new,
    from_dict = _ext_contrib_entry_from_dict,
    decode = _ext_contrib_entry_decode,
)

schema = struct(
    ExtData = ext_data,
    ExtensionEntry = extension_entry,
    ExtSource = ext_source,
    ExtExternalTarget = ext_external_target,
    ExtContribTarget = ext_contrib_target,
    ExtExternalEntry = ext_external_entry,
    ExtContribEntry = ext_contrib_entry,
)
