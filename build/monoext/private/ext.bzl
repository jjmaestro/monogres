"""
Public API for the extensions hub repo layer.

This module runs in module extension context. It calls `Label()` and
`download_archives()`. It builds entries from extension metadata and delegates
hub file generation to the `ext_repo` repository rule in `ext/hub.bzl`.
"""

load(
    "@download_archives//download/archives:extensions.bzl",
    download_archives = "archives",
)
load("//monoext/private:pkgs.bzl", "pkgs_group")
load("//monoext/private:repo_names.bzl", "bind", "repo_names")
load("//monoext/private/ext:compat.bzl", "is_compatible")
load("//monoext/private/ext:hub.bzl", "ext_repo")
load("//monoext/private/ext:schema.bzl", _ExtSchema = "schema")

def create_ext_src(ctx, hub_name, catalog_label):
    """Read extension catalog, create per-ext source repos, return ExtData.

    Reads the catalog `index.json` and each extension's `repo.json`. For
    non-contrib extensions, creates `@{hub_name}_src__{ext}` via
    `download_archives` (lazy per-version fetching).

    Must be called from a module extension context.

    Args:
        ctx: Module extension context.
        hub_name: Apparent name of the extensions hub repo (the derived
            `{tag.name}_ext`), used to derive source repo names as
            `{hub_name}_src__{ext_name}`.
        catalog_label: Label of the catalog `index.json`, or `None`.

    Returns:
        An `ExtData` struct (see `//monoext/private/ext:schema.bzl`).
    """
    if not catalog_label:
        return _ExtSchema.ExtData.new()

    catalog = json.decode(ctx.read(catalog_label))
    extensions = {}

    for ext_name in sorted(catalog.get("extensions", [])):
        repo_json = catalog_label.relative(":%s/repo.json" % ext_name)
        repo = json.decode(ctx.read(repo_json))
        metadata = repo.get("metadata", {})
        source_repo = repo_names.ext_src(hub_name, ext_name)

        download_archives(
            ctx = ctx,
            name = source_repo,
            index = repo_json,
            patches = {
                Label(patch["label"]): patch["spec"]
                for patch in metadata.get("patches", [])
            },
        )

        f = bind(src = source_repo)
        extensions[ext_name] = _ExtSchema.ExtensionEntry.new(
            ext_versions = sorted(repo.get("versions", {}).keys()),
            is_contrib = False,
            lock = f("@{src}//:lock.json"),
            metadata = metadata,
            source_repo = source_repo,
        )

    for ext_name in sorted(catalog.get("contrib", [])):
        repo_json = catalog_label.relative(":contrib/%s/repo.json" % ext_name)
        repo = json.decode(ctx.read(repo_json))

        extensions[ext_name] = _ExtSchema.ExtensionEntry.new(
            ext_versions = sorted(repo.get("versions", [])),
            is_contrib = True,
            metadata = repo.get("metadata", {}),
        )

    pkgs_groups = [
        pkgs_group(ext_name, ext.ext_versions, ext.metadata)
        for ext_name, ext in extensions.items()
        if not ext.is_contrib
    ]

    return _ExtSchema.ExtData.new(
        pkgs_groups = pkgs_groups,
        extensions = extensions,
    )

def _build_external(extensions, versions_deps, base_versions, hub_name):
    """Builds JSON-encoded `ExtExternalEntry` values for ext_repo.

    `hub_name` is used to pre-qualify all `@{hub_name}//{ext}/{ext_v}/...` alias
    labels baked onto each `ExtExternalTarget` (`artifact`,
    `source.{dir,files}`, `deps.*`) and each `ExtSource` before the JSON
    boundary. The repo rule in `ext/hub.bzl` then renders consumers straight
    from the schema without ever reading its apparent name.
    """
    entries = {}

    for name in sorted(extensions):
        ext = extensions[name]
        metadata = ext.metadata
        ext_versions_deps = versions_deps.get(name, {})

        compatible_base_versions = {
            ext_version: [
                base_v
                for base_v in base_versions
                if is_compatible(name, ext_version, base_v, metadata)
            ]
            for ext_version in ext.ext_versions
        }

        entry = _ExtSchema.ExtExternalEntry.new(
            ext_hub_name = hub_name,
            ext_name = name,
            ext_versions = ext.ext_versions,
            compatible_base_versions = compatible_base_versions,
            source_repo = ext.source_repo,
            ext_versions_deps = ext_versions_deps,
        )
        entries[name] = json.encode(entry)

    return entries

def _build_contrib(extensions, hub_name):
    """Builds JSON-encoded `ExtContribEntry` values for ext_repo.

    `hub_name` is used to pre-qualify `@{hub_name}//contrib/{name}/{base_v}:tar`
    artifact labels baked onto each `ExtContribTarget` before the JSON boundary.
    """
    entries = {}

    for name in sorted(extensions):
        ext = extensions[name]
        entry = _ExtSchema.ExtContribEntry.new(
            ext_hub_name = hub_name,
            ext_name = name,
            ext_versions = ext.ext_versions,
            metadata = ext.metadata,
        )
        entries[name] = json.encode(entry)

    return entries

def create_ext(
        hub_name,
        extensions,
        pkgs_result,
        catalog,
        base_versions,
        base_hub_name,
        archs,
        build_repo = "monogres"):
    """Build entries and create the extensions hub repo.

    Sources must already be instantiated via `create_ext_src`; this function
    only builds the hub from the enriched extensions dict.

    Must be called from a module extension context.

    Args:
        hub_name: Apparent name of the extensions hub repo (the derived
            `{tag.name}_ext`).
        extensions: `{ext_name: ExtensionEntry}` dict from `create_ext_src`.
        pkgs_result: `PkgsResult` struct from `create_pkgs()`.
        catalog: Label of the catalog `index.json`.
        base_versions: Sorted list of base version strings.
        base_hub_name: Apparent name of the base hub repo (the `tag.name`
            value). Extension builds and `PG_CFG` are resolved from this repo.
        archs: List of architecture names for per-arch targets.
        build_repo: Repo containing the build rules (default `"monogres"`).
    """
    external = {n: e for n, e in extensions.items() if not e.is_contrib}
    contrib = {n: e for n, e in extensions.items() if e.is_contrib}

    locks = {n: e.lock for n, e in external.items()}

    entries = _build_external(
        external,
        pkgs_result.versions_deps,
        base_versions,
        hub_name,
    )

    entries |= _build_contrib(contrib, hub_name)

    # Per-PG-version buildtime VersionDeps for the layered `_base/<pg_v>`
    # packages: every PGXS extension built against a given PG version sees that
    # version's buildtime sysroot as `-idirafter` / `-L` overlay.
    pg_versions_deps = pkgs_result.versions_deps.get("postgres", {})

    ext_repo(
        name = hub_name,
        archs = list(archs),
        catalog = catalog,
        entries = entries,
        base_hub_name = base_hub_name,
        locks = locks,
        build_repo = build_repo,
        pg_versions_deps = json.encode(pg_versions_deps),
    )

testing = struct(
    _build_external = _build_external,
    _build_contrib = _build_contrib,
)
