"""
Public API for the base hub repo layer.

The base layer is the foundation flavor (currently PostgreSQL); future flavors
(e.g. PG-derived databases) plug in by providing their own `repo.json` and
sharing the same hub generation pipeline.

This module runs in module extension context. It calls `Label()` and
`download_archives()` to create `@{name}_src`, registers per-version introspect
repos (lazy, only fetched when their data is loaded), computes build options for
each `version x option_set` combo, and delegates hub file generation to the
`base_repo` repo rule.
"""

load(
    "@download_archives//download/archives:extensions.bzl",
    download_archives = "archives",
)
load("@download_archives//lib:index.bzl", Index = "index")
load("@platform_debian//:versions.bzl", "RELEASE")
load("@version_utils//version:version.bzl", Version = "version")
load("//monoext/private:pkgs.bzl", "pkgs_group")
load("//monoext/private:repo_names.bzl", "bind", "repo_names")
load("//monoext/private/base:compat.bzl", "is_compatible_with")
load("//monoext/private/base:hub.bzl", "base_repo")
load(
    "//monoext/private/base:introspect.bzl",
    "pg_introspect_paths_repo",
    "pg_introspect_version_repo",
)
load("//monoext/private/base:schema.bzl", _BaseSchema = "schema")
load(
    "//monoext/private/base/build_options:flavors.bzl",
    "DEFAULT_FLAVOR",
    "FLAVORS",
)
load("//monoext/private/pkgs:schema.bzl", _PkgsSchema = "schema")
load("//monoext/private/test:introspect.bzl", "introspect_payload")

# Build options layered onto a production option set to produce its test-enabled
# sibling, rendered as the `{version}/{option_set}/test/` build by
# `versions.bzl`. Applied as a post-compute override on the options dict so it
# beats the production pins (`tap_tests` is pinned `disabled` in every set)
# without perturbing the production `:tar`. Flavor-agnostic: it speaks the Meson
# option vocabulary that `configure_args.bzl` also maps to autoconf `--enable-X`
# on the make path. Additive; extend with cassert / injection_points / debug
# when those test lanes land.
_TEST_OVERLAY = {
    "tap_tests": "enabled",
}

def _release_gated(version, release_incompatible, active_debian):
    """Whether `version` is gated off the active Debian release.

    `release_incompatible` is `metadata.release_incompatible`: rules shaped
    `{pg: <PGVER spec>, min_debian: <int>, reason: <str>}`. A version is gated
    when the active Debian release is at least `min_debian` and the version
    matches the rule's `pg` spec. Drops old PG minors whose vendored code
    predates an upstream toolchain-compat backpatch from a newer release while
    keeping them on older ones.
    """
    for rule in release_incompatible:
        if active_debian < rule["min_debian"]:
            continue
        if is_compatible_with(version, rule["pg"]):
            return True
    return False

def create_base_src(ctx, hub_name, base_label):
    """Create base source repos, introspect repos, and return base_data.

    Parses the repo.json index, creates `@{hub_name}_src` (lazy per-version
    downloads via `download_archives`), and registers per-version introspect
    repos (lazy; only fetched when their data is loaded).

    Must be called from a module extension context.

    Args:
        ctx: Module extension context.
        hub_name: Apparent name of the base hub repo (the `tag.name` value).
        base_label: Label of the base flavor's `repo.json` index.

    Returns:
        A `BaseData` struct (see `//monoext/private/base:schema.bzl`).
    """
    src_repo = repo_names.base_src(hub_name)
    index = Index.new(src_repo, ctx.read(base_label))
    metadata = index.metadata

    # Release-by-version gate: drop PG minors that cannot build on the active
    # Debian release (see `_release_gated` + `metadata.release_incompatible`).
    # Gated versions are absent (not built, tested, or introspected) here but
    # preserved on older releases.
    active_debian = int(RELEASE.version)
    release_incompatible = metadata.get("release_incompatible", [])
    versions = [
        v
        for v in sorted(index.repos.keys())
        if not _release_gated(v, release_incompatible, active_debian)
    ]

    flavor = metadata.get("flavor", DEFAULT_FLAVOR)
    if flavor not in FLAVORS:
        fail("Unknown flavor %r in %s (known: %s)" % (
            flavor,
            base_label,
            sorted(FLAVORS.keys()),
        ))

    download_archives(
        ctx = ctx,
        name = src_repo,
        index = base_label,
        patches = {
            Label(patch["label"]): patch["spec"]
            for patch in metadata.get("patches", [])
        },
        version_scheme = "pgver",
    )

    # Multi-source support: `metadata.extra_sources` declares sibling tarballs
    # to download alongside the primary source tree. Each entry has its own
    # `repo.json`-shaped index file (with its own sources/versions/patches),
    # which we hand to `download_archives` to produce a parallel set of
    # per-version repos. The build wrapper (`pg_build_make`) merges these into
    # the primary tree at `contrib_dir` at build time.
    extra_sources = {}
    for key, ext_config in metadata.get("extra_sources", {}).items():
        ext_index = Label(ext_config["index"])
        ext_repo = "{src}_{key}".format(src = src_repo, key = key)
        ext_index_data = json.decode(ctx.read(ext_index))
        ext_metadata = ext_index_data.get("metadata", {})
        download_archives(
            ctx = ctx,
            name = ext_repo,
            index = ext_index,
            patches = {
                Label(patch["label"]): patch["spec"]
                for patch in ext_metadata.get("patches", [])
            },
            version_scheme = "pgver",
        )
        extra_sources[key] = struct(
            repo = ext_repo,
            contrib_dir = ext_config.get("contrib_dir", ""),
            # Names (relative to `<extra_path>/<contrib_dir>/`) to skip during
            # the post-install PGXS pass. The merge step still copies these
            # subdirs (so peer overlays can `#include` their headers); only
            # `pg_build_make`'s `pgxs_install_extras` honors the list. Default
            # empty — an escape hatch for overlay contribs that need build-env
            # pieces not plumbed through the PGXS pass.
            exclude = ext_config.get("exclude", []),
        )

    # register per-version introspect repos (lazy, no downloads at this point)
    introspect_meta = metadata.get("introspect", {})
    introspect_repos = {}
    introspect_paths_repos = {}

    flavor_mod = FLAVORS[flavor]

    for v, repos in index.repos.items():
        if v not in versions:  # release-gated; see the version filter above
            continue
        if not repos:
            continue

        introspect_jsons = introspect_meta.get(v, {})
        if not introspect_jsons:
            continue

        jsons_by_label = {
            label: option_set
            for option_set, label in introspect_jsons.items()
            if label
        }

        # Per-version build system (the postgres flavor splits on version:
        # PG <= 15.x -> make, PG 16.0+ -> meson). Threaded into Layer 2 so the
        # introspect repo knows whether to read `meson_options.txt` and
        # `contrib/<name>/meson.build` (Meson) or skip those reads (make sources
        # have no equivalent; their introspect JSONs already encode the
        # installed paths without the source-side metadata).
        build_system = flavor_mod.build_system(v)

        introspect_repo_name = repo_names.pg_introspect(hub_name, v)
        base_src_ver = repo_names.base_src_version(hub_name, v)
        f = bind(src = base_src_ver, v = v, source = repos[0].source)
        pg_introspect_version_repo(
            name = introspect_repo_name,
            version = v,
            pg_src_version_dir = f("@{src}//{v}/{source}:BUILD.bazel"),
            introspect_jsons = jsons_by_label,
            build_system = build_system,
        )
        introspect_repos[v] = introspect_repo_name

        paths_repo_name = repo_names.pg_introspect_paths(hub_name, v)
        pg_introspect_paths_repo(
            name = paths_repo_name,
            version = v,
            flavor = flavor,
            introspect_jsons = jsons_by_label,
        )
        introspect_paths_repos[v] = paths_repo_name

    return _BaseSchema.BaseData.new(
        default_version = versions[-1],
        introspect_repos = introspect_repos,
        introspect_paths_repos = introspect_paths_repos,
        metadata = metadata,
        pkgs_group = pkgs_group(
            flavor,
            versions,
            metadata,
            version_scheme = Version.SCHEME.PGVER,
        ),
        source_repo = src_repo,
        versions = versions,
        flavor = flavor,
        extra_sources = extra_sources,
    )

def _build_entries(base_data, versions_deps, hub_name):
    """Build JSON-encoded `BaseEntry` values for base_repo, one per base version.

    Args:
        base_data: `BaseData` struct from `create_base_src`.
        versions_deps: `{version: VersionDeps}` from `create_pkgs()`.
        hub_name: Apparent name of the base hub (the `tag.name` value), used to
            pre-qualify all `@{hub_name}//...` alias labels baked onto each
            `BaseTarget` (`artifact`, `source.{dir,files}`, `deps.*`) and each
            `BaseEntry.source` before the JSON boundary.

    Returns:
        Dict of `{version: json_encoded_entry}`.
    """
    metadata = base_data.metadata
    source_repo = base_data.source_repo
    build_options_metadata = metadata.get("build_options", {})
    flavor_mod = FLAVORS[base_data.flavor]
    entries = {}

    for version in sorted(base_data.versions):
        vd = versions_deps.get(version) or _PkgsSchema.VersionDeps.new()

        # Per-version build system selector. The `postgres` flavor splits per
        # version (PG <= 15.x → make, PG 16.0+ → meson); other flavors return a
        # constant.
        build_system = flavor_mod.build_system(version)

        # Upstream PostgreSQL base for this flavor version (postgres: the
        # version itself; forks: the PG release they track). Lets the build
        # wrapper gate PG-version-specific tooling on the real PG version, not
        # the flavor's own version number.
        pg_base_version = flavor_mod.pg_base_version(version)

        # Per-target snapshot of extra_sources: `{key: {dir, contrib_dir,
        # exclude}}` where `dir` is a per-version `:dir` filegroup label on the
        # sibling source repo created in `create_base_src`. The build wrapper
        # consumes this at the BUILD-file level to merge sibling trees into the
        # primary build tree.
        per_version_extras = {
            key: {
                "contrib_dir": src.contrib_dir,
                "dir": "@{repo}//{v}:dir".format(repo = src.repo, v = version),
                "exclude": src.exclude,
            }
            for key, src in base_data.extra_sources.items()
        }

        targets = []
        for option_set in flavor_mod.OPTION_SETS:
            options, auto_features = flavor_mod.build_options(
                version,
                option_set,
                build_options_metadata,
            )

            # Test-enabled sibling options: production options plus the
            # `_TEST_OVERLAY` (tap_tests, ...). `versions.bzl` renders these
            # into the `{version}/{option_set}/test/` build; the production
            # `:tar` keeps `options` untouched. `auto_features` is shared (the
            # overlay only forces specific feature values, not the auto
            # default).
            test_build_options = dict(options)
            test_build_options.update(_TEST_OVERLAY)

            # injection_points is a meson PG17+ option; gate on the catalog's
            # compatibility spec (metadata.build_options.injection_points) so
            # the test variant enables it only where the build accepts it.
            # Enabling it is what makes the regenerated test introspect carry
            # the injection_points module suites and enable_injection_points=yes
            # env faithfully, with no codegen-side override.
            ip_meta = build_options_metadata.get("injection_points")
            ip_spec = ip_meta.get("compatible") if ip_meta else None
            if ip_spec and is_compatible_with(version, ip_spec):
                test_build_options["injection_points"] = "true"

            targets.append(_BaseSchema.BaseTarget.new(
                hub_name = hub_name,
                version = version,
                option_set = option_set,
                auto_features = auto_features,
                build_options = options,
                test_build_options = test_build_options,
                version_deps = vd,
                build_system = build_system,
                pg_base_version = pg_base_version,
                extra_sources = per_version_extras,
            ))

        entry = _BaseSchema.BaseEntry.new(
            hub_name = hub_name,
            version = version,
            source_repo = source_repo,
            targets = targets,
            versions_deps = vd,
        )
        entries[version] = json.encode(entry)

    return entries

def create_base(hub_name, base_data, pkgs_result, archs, build_repo = "monogres"):
    """Create the base hub repo with build targets and introspect data.

    Must be called from a module extension context.

    Args:
        hub_name: Apparent name of the base hub repo (the `tag.name` value).
        base_data: `BaseData` struct from `create_base_src`.
        pkgs_result: `PkgsResult` struct from `create_pkgs()`.
        archs: List of architecture names for per-arch targets.
        build_repo: Build repo name (default "monogres").
    """
    flavor = base_data.flavor
    versions_deps = pkgs_result.versions_deps.get(flavor, {})

    entries = _build_entries(base_data, versions_deps, hub_name)

    # `introspect_payload` supplies `option_sets` + the test-introspect attrs;
    # the base hub renders the core/pl/module suites alongside the build
    # targets.
    base_repo(
        name = hub_name,
        archs = list(archs),
        entries = entries,
        default_version = base_data.default_version,
        introspect_repos = base_data.introspect_repos,
        introspect_paths_repos = base_data.introspect_paths_repos,
        pg_src = "@%s" % base_data.source_repo,
        build_repo = build_repo,
        flavor = flavor,
        **introspect_payload(hub_name, base_data)
    )

testing = struct(
    _build_entries = _build_entries,
)
