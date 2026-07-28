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
load("//monoext/private/ext/crates:pool.bzl", "pool")
load("//monoext/private/test:introspect.bzl", "introspect_payload")

# The SQL generator a pgrx extension build runs, as a `Cargo.lock` per pgrx
# version: the `.pgrxsc` decoder and the SQL emitter behind it both live in
# `pgrx-sql-entity-graph`, so the generator has to be built against the same
# pgrx release the extension was. See
# `//tools/pgrxsc_sql/<version>:BUILD.bazel`.
#
# Each of these locks goes through the same crate pool as the extensions', so
# their closures are declared once, alongside theirs, sharing whatever overlaps.
_PGRX_TOOL_LOCK = "//tools/pgrxsc_sql/{}:Cargo.lock"

# The crate whose pin in an extension's own lock selects that generator.
_PGRX_CRATE = "pgrx"

def _synth_ext_test_meta(
        ctx,
        catalog_label,
        ext_name,
        ext_versions,
        metadata,
        base_flavor):
    """Synthesize an extension's `test_ext` from its committed introspects.

    The external test model mirrors PostgreSQL core: an extension's test
    universe is DISCOVERED, not hand-transcribed. Each ext version ships a
    committed `introspect/<ext>~<ver>.json` (produced by the build's `make -n
    installcheck` dry run; see `tools/ext_introspect.py`) naming its regress
    suite, its TAP `.pl` files, and its installed `*.control` names. This reads
    those per-version introspects (cheap committed reads, no source fetch, so
    the hub stays lazy) and folds the catalog `repo.json` customizations on top,
    producing the same `test_ext` shape (`{smoke, test:
    {version_spec: {slug: decl}}}`) the hub renderer already consumes.

    The discovered suites are keyed by each version's own `compatible_with`
    spec, so the correct suite resolves per base version. The
    `metadata.test_ext` in `repo.json` now carries only what discovery cannot
    know:

    - `smoke`: `preload` / `cascade` (the discovered `extensions` default to
      the installed `*.control` names, and may be overridden here).
    - `test_overrides`: `{slug: {locale, exclusive, temp_config, temp_instance,
      encoding, dbname, load_extensions, exclude, exclude_tests}}`, folded onto
      the discovered decl for that slug (`exclude` drops the suite;
      `exclude_tests` drops individual test / `.pl` names, either as a flat list
      or a version-spec-keyed map resolved per base version).
    - `test`: `{version_spec: {slug: decl}}` custom suites (integration or
      manual) that no `installcheck` can produce, merged on top of the
      discovered ones.
    - `requires`: `[ext_name, ...]` prerequisite catalog extensions whose
      artifact + runtime-deps trees are overlaid into every test instance for
      this extension (e.g. pgrouting requires postgis for `CREATE EXTENSION`).

    Returns `(test_ext, introspect_versions)`: the untouched `metadata.test_ext`
    and an empty version list when the extension ships no introspects yet, so
    extensions migrate onto discovery one at a time by committing their
    `introspect/` files.
    """
    overrides = metadata.get("test_ext", {})
    compat = metadata.get("compatible_with", {}).get(base_flavor, {})
    smoke_over = overrides.get("smoke", {})
    slug_over = overrides.get("test_overrides", {})
    extra_test = overrides.get("test", {})

    test = {}
    controls = {}
    introspect_versions = []

    for ext_v in ext_versions:
        label = catalog_label.relative(
            ":%s/introspect/%s~%s.json" % (ext_name, ext_name, ext_v),
        )

        # Watch the introspect path (even while absent) so committing or
        # regenerating one re-triggers this extension and updates the lockfile;
        # `ctx.path(...).exists` alone does not register a dependency, which
        # would leave an added introspect unseen until an unrelated input
        # changed.
        ctx.watch(label)

        if not ctx.path(label).exists:
            continue

        introspect_versions.append(ext_v)
        introspect = json.decode(ctx.read(label))
        spec = compat.get(ext_v, "*")

        slug_map = {}
        for decl in introspect.get("test_suites", []):
            slug = decl["slug"]
            over = slug_over.get(slug, {})

            if over.get("exclude"):
                continue

            merged = {k: v for k, v in decl.items() if k != "slug"}
            for k, v in over.items():
                if k not in ("exclude", "exclude_tests"):
                    merged[k] = v

            excluded = over.get("exclude_tests")
            if excluded:
                # `exclude_tests` drops individual test / `.pl` names. It is
                # either a flat list (drop on every base version) or a
                # version-spec-keyed map (`{spec: [name, ...]}`, drop only on
                # versions matching the spec, e.g. a golden that lands only on
                # one PG major). It is resolved against the concrete base
                # version downstream, alongside the spec-keyed `tests` map.
                merged["exclude_tests"] = excluded

            slug_map[slug] = merged

        for slug, decl in extra_test.get(spec, {}).items():
            slug_map[slug] = decl

        if slug_map:
            test[spec] = slug_map

        for control in introspect.get("controls", []):
            controls[control] = None

    if not introspect_versions:
        return overrides, []

    result = {}
    smoke = dict(smoke_over)
    if "extensions" not in smoke and controls:
        smoke["extensions"] = sorted(controls)

    if smoke:
        result["smoke"] = smoke

    if test:
        result["test"] = test

    # Prerequisite catalog extensions (their artifact + runtime-deps trees are
    # overlaid into every test instance for this extension, so its `CREATE
    # EXTENSION` can resolve a hard dependency such as pgrouting on postgis).
    # Discovery cannot know these, so they pass through untouched.
    requires = overrides.get("requires")
    if requires:
        result["requires"] = requires

    return result, introspect_versions

def _read_cargo(ctx, catalog_label, ext_name, ext_versions, declared):
    """Read a pgrx extension's committed locks into the shared crate pool.

    One `Cargo.lock` per extension version, committed to the catalog rather than
    taken from the extension's source archive, so declaring the crate repos does
    not download the extension and the hub stays lazy (the same trade the
    committed introspect JSONs make for the base hub).

    Args:
        ctx: Module extension context.
        catalog_label: Label of the catalog `index.json`.
        ext_name: Extension name.
        ext_versions: The extension's versions.
        declared: The pool's `{repo_name: sha256}`, mutated in place.

    Returns:
        `{ext_version: {"lock": label, "crates": {repo_name: dir_name}, "pgrx":
        version}}`, where `pgrx` is the version the lock pins and so the
        generator that can read the SQL section this version will emit.
    """
    cargo = {}

    for ext_v in ext_versions:
        label = catalog_label.relative(
            ":%s/cargo/%s/Cargo.lock" % (ext_name, ext_v),
        )
        ctx.watch(label)

        if not ctx.path(label).exists:
            fail((
                "%s %s declares build_system pgrx but has no lock at %s. " +
                "A pgrx build resolves its crates from the lock alone, so " +
                "the lock is what the catalog has to carry."
            ) % (ext_name, ext_v, label))

        crates = pool.parse_lock(ctx.read(label), lock_label = str(label))

        cargo[ext_v] = {
            "crates": pool.declare(crates, declared),
            "lock": str(label),
            "pgrx": pool.pinned_version(
                crates,
                _PGRX_CRATE,
                lock_label = str(label),
            ),
        }

    return cargo

def _read_pgrx_tools(ctx, pgrx_versions, declared):
    """Read the SQL generator locks for `pgrx_versions` into the crate pool.

    One generator per pgrx version any pgrx extension pins, and only for the
    versions actually pinned: a catalog with no pgrx extension builds no
    generator at all, and adding one pgrx version does not build the others'.

    Args:
        ctx: Module extension context.
        pgrx_versions: The pgrx versions the catalog's extensions pin.
        declared: The pool's `{repo_name: sha256}`, mutated in place.

    Returns:
        `{pgrx_version: {repo_name: dir_name}}`, the closure per generator.
    """
    crates = {}

    for pgrx_v in sorted(pgrx_versions):
        lock = Label(_PGRX_TOOL_LOCK.format(pgrx_v))
        ctx.watch(lock)

        if not ctx.path(lock).exists:
            fail((
                "no pgrx SQL generator for pgrx %s (looked for %s). An " +
                "extension pinning that pgrx emits a `.pgrxsc` section only " +
                "the generator built against the same release can read, so " +
                "adding the pin means adding the generator package too."
            ) % (pgrx_v, lock))

        crates[pgrx_v] = pool.declare(
            pool.parse_lock(ctx.read(lock), lock_label = str(lock)),
            declared,
        )

    return crates

def create_ext_src(
        ctx,
        hub_name,
        catalog_label,
        base_flavor = "postgres",
        crates_declared = None):
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
        base_flavor: Base flavor identity (e.g. "postgres", "ivorysql"). Used to
            filter contrib metadata to the flavor's slice.
        crates_declared: The crate pool's `{repo_name: sha256}`, mutated in
            place. Hub-independent, so callers pass ONE for the whole module
            extension evaluation and every flavor shares the pool. A fresh dict
            when omitted, which is right for a single-hub caller.

    Returns:
        An `ExtData` struct (see `//monoext/private/ext:schema.bzl`).
    """
    if not catalog_label:
        return _ExtSchema.ExtData.new()

    if crates_declared == None:
        crates_declared = {}

    catalog = json.decode(ctx.read(catalog_label))
    extensions = {}

    for ext_name in sorted(catalog.get("extensions", [])):
        repo_json = catalog_label.relative(":%s/repo.json" % ext_name)
        repo = json.decode(ctx.read(repo_json))
        metadata = repo.get("metadata", {})
        source_repo = repo_names.ext_src(hub_name, ext_name)

        ext_versions = sorted(repo.get("versions", {}).keys())

        # Discovery-driven testing: when an extension commits `introspect/`
        # files, its `test_ext` is synthesized from those (discovered test
        # universe) plus the `repo.json` customizations, converging the external
        # lane onto PostgreSQL core's committed-introspect model.
        synth_test_ext, introspect_versions = _synth_ext_test_meta(
            ctx,
            catalog_label,
            ext_name,
            ext_versions,
            metadata,
            base_flavor,
        )

        if synth_test_ext:
            metadata = dict(metadata)
            metadata["test_ext"] = synth_test_ext
        elif "test_ext" in metadata:
            metadata = {k: v for k, v in metadata.items() if k != "test_ext"}

        download_archives(
            ctx = ctx,
            name = source_repo,
            index = repo_json,
            patches = {
                Label(patch["label"]): patch["spec"]
                for patch in metadata.get("patches", [])
            },
        )

        # A pgrx extension resolves its Rust dependency closure from a committed
        # lock, which becomes crate pool repos shared with every other pgrx
        # extension (and with the SQL generator declared below).
        cargo = {}
        if metadata.get("build_system") == "pgrx":
            cargo = _read_cargo(
                ctx,
                catalog_label,
                ext_name,
                ext_versions,
                crates_declared,
            )

        f = bind(src = source_repo)
        extensions[ext_name] = _ExtSchema.ExtensionEntry.new(
            ext_versions = ext_versions,
            is_contrib = False,
            lock = f("@{src}//:lock.json"),
            metadata = metadata,
            source_repo = source_repo,
            introspect_versions = introspect_versions,
            cargo = cargo,
        )

    for ext_name in sorted(catalog.get("contrib", [])):
        repo_json = catalog_label.relative(":contrib/%s/repo.json" % ext_name)
        repo = json.decode(ctx.read(repo_json))

        versions_raw = repo.get("versions", {})
        files_raw = repo.get("metadata", {}).get("files", {})

        # Support both old schema (versions: [...]) and new (versions: {flavor:
        # [...]})
        if type(versions_raw) == "list":
            flavor_versions = sorted(
                versions_raw,
            ) if base_flavor == "postgres" else []
            files_by_flavor = {"postgres": files_raw}
        else:
            flavor_versions = sorted(versions_raw.get(base_flavor, []))
            files_by_flavor = files_raw

        if not flavor_versions:
            continue  # contrib does not ship for this flavor → skip

        metadata = dict(repo.get("metadata", {}))
        metadata["files"] = files_by_flavor.get(base_flavor, {})

        extensions[ext_name] = _ExtSchema.ExtensionEntry.new(
            ext_versions = flavor_versions,
            is_contrib = True,
            metadata = metadata,
        )

    pkgs_groups = [
        pkgs_group(ext_name, ext.ext_versions, ext.metadata)
        for ext_name, ext in extensions.items()
        if not ext.is_contrib
    ]

    # A generator is only built when something needs it, so its closure is only
    # declared then too: one per pgrx version the catalog's extensions pin.
    pgrx_crates = _read_pgrx_tools(
        ctx,
        {
            version["pgrx"]: None
            for ext in extensions.values()
            for version in ext.cargo.values()
        },
        crates_declared,
    )

    return _ExtSchema.ExtData.new(
        pkgs_groups = pkgs_groups,
        extensions = extensions,
        pgrx_crates = pgrx_crates,
    )

def _build_external(extensions, versions_deps, base_versions, base_flavor, hub_name):
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
                if is_compatible(
                    name,
                    ext_version,
                    base_flavor,
                    base_v,
                    metadata,
                )
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
            base_flavor = base_flavor,
            build_system = metadata.get("build_system", "pgxs"),
            build_args = metadata.get("build_args", []),
            remap_paths = metadata.get("remap_paths", {}),
            crate_dir = metadata.get("crate_dir", ""),
            cargo = ext.cargo,
        )
        entries[name] = json.encode(entry)

    return entries

def _ver_key(version):
    return [int(part) for part in version.split(".")]

def _introspect_manifest(external, base_versions, base_flavor):
    """Derive the regen + freshness manifest from the catalog, not a hand list.

    For every external ext version that ships a committed introspect, name the
    representative base build whose discovery is canonical: the newest base
    minor compatible with that ext version. The test universe an extension
    discovers varies by base MAJOR (a new PG major may add or drop a regress
    test), so the newest compatible minor is a faithful, low-churn choice.

    Returns a `{ext: {ext_version: base_version}}` dict (mirroring the catalog's
    ext -> versions nesting) that flows to the hub, which writes the
    `introspect.bzl` the catalog loads, so nothing is hand-enumerated.
    """
    manifest = {}
    for name in sorted(external):
        ext = external[name]
        versions = {}
        for ext_version in ext.introspect_versions:
            compatible = [
                base_v
                for base_v in base_versions
                if is_compatible(
                    name,
                    ext_version,
                    base_flavor,
                    base_v,
                    ext.metadata,
                )
            ]
            if not compatible:
                continue
            versions[ext_version] = sorted(compatible, key = _ver_key)[-1]
        if versions:
            manifest[name] = versions
    return manifest

def _build_contrib(extensions, hub_name, base_flavor = "postgres"):
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
            base_flavor = base_flavor,
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
        base_flavor,
        base_data,
        archs,
        pgrx_crates = {},
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
        base_flavor: Base flavor identity (e.g. "postgres", "ivorysql").
        base_data: `BaseData` from `create_base_src`. Supplies the
            test-introspect inputs (introspect, overrides) for the contrib test
            suites the extensions hub now renders under
            `contrib/<name>/<v>/tests`.
        archs: List of architecture names for per-arch targets.
        pgrx_crates: `{pgrx_version: {repo_name: dir_name}}` from
            `create_ext_src`: the crate pool repos backing one SQL generator per
            pgrx version the extensions pin. Empty when no extension is pgrx, in
            which case the hub renders no generator at all.
        build_repo: Repo containing the build rules (default `"monogres"`).
    """
    external = {n: e for n, e in extensions.items() if not e.is_contrib}
    contrib = {n: e for n, e in extensions.items() if e.is_contrib}

    locks = {n: e.lock for n, e in external.items()}

    entries = _build_external(
        external,
        pkgs_result.versions_deps,
        base_versions,
        base_flavor,
        hub_name,
    )

    entries |= _build_contrib(contrib, hub_name, base_flavor)

    # The external extensions' `metadata.test_ext` (the smoke + upstream regress
    # introspect), threaded to the hub so it renders the external test packages
    # under `<ext>/<ext_v>/<base_v>/tests` alongside the builds. Keyed by
    # extension name; extensions that declare no `test_ext` are dropped.
    external_test_meta = {
        n: e.metadata["test_ext"]
        for n, e in external.items()
        if e.metadata.get("test_ext")
    }

    # Per-base-version buildtime VersionDeps for the layered `_base/<base_v>`
    # packages: every PGXS extension built against a given base version sees
    # that version's buildtime sysroot as `-idirafter` / `-L` overlay.
    #
    # Keyed by THIS hub's flavor, which is the key `pkgs_group` is built under
    # (`base.bzl` names the group after the flavor). Naming any other flavor
    # here reads as an empty dict, and an empty dict renders no `_base/<base_v>`
    # package at all, which every extension compatible with this flavor is
    # already pointing at.
    base_versions_deps = pkgs_result.versions_deps.get(base_flavor, {})

    # `introspect_payload` (keyed on the BASE hub, where the install trees live)
    # supplies `option_sets` + the test-introspect attrs; the extensions hub
    # renders the contrib suites under `contrib/<name>/<v>/tests` alongside the
    # builds. The regen + freshness manifest for the committed test introspects,
    # derived from the catalog (which ext versions ship an introspect and their
    # newest compatible base), so the catalog `ext_introspect(...)` targets are
    # never hand-enumerated.
    ext_introspect_manifest = _introspect_manifest(
        external,
        base_versions,
        base_flavor,
    )

    ext_repo(
        name = hub_name,
        archs = list(archs),
        catalog = catalog,
        entries = entries,
        base_hub_name = base_hub_name,
        base_flavor = base_flavor,
        locks = locks,
        build_repo = build_repo,
        pgrx_crates = json.encode(pgrx_crates),
        base_versions_deps = json.encode(base_versions_deps),
        external_test_meta = json.encode(external_test_meta),
        ext_introspect_manifest = json.encode(ext_introspect_manifest),
        **introspect_payload(base_hub_name, base_data)
    )

testing = struct(
    _build_external = _build_external,
    _build_contrib = _build_contrib,
)
