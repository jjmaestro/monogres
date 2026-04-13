"""
Unit tests for monoext/private/base.bzl pure helpers.

Exercises `_build_entries(base_data, versions_deps, hub_name)`, the pure
function that maps a `BaseData` + per-version deps into the JSON-encoded
`BaseEntry` values passed to `base_repo.entries`. `hub_name` is used to
pre-qualify `@{hub_name}//{version}/deps/...` alias labels baked onto each
`BaseTarget.deps` before the JSON boundary.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private:base.bzl", _Base = "testing")

# buildifier: disable=bzl-visibility
load("//monoext/private/base:schema.bzl", _BaseSchema = "schema")

# buildifier: disable=bzl-visibility
load("//monoext/private/base/build_options:pg.bzl", "OPTION_SETS")

# buildifier: disable=bzl-visibility
load("//monoext/private/pkgs:schema.bzl", _PkgsSchema = "schema")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _base_data(versions):
    return _BaseSchema.BaseData.new(
        default_version = versions[-1],
        introspect_repos = {},
        introspect_paths_repos = {},
        metadata = {},
        pkgs_group = struct(
            name = "postgres",
            versions = versions,
            metadata = {},
        ),
        source_repo = "pg_src",
        versions = versions,
    )

def _buildtime_deps(sysroot_labels_by_arch):
    bt = _PkgsSchema.DepsInfo.new(
        packages = ["libssl-dev"],
        pkgs_labels = ["@pg_pkgs//deb/libssl-dev:libssl-dev"],
        sysroot_labels_by_arch = sysroot_labels_by_arch,
    )
    return _PkgsSchema.VersionDeps.new(buildtime = bt)

# --- build_entries ---------------------------------------------------------

def _build_entries_one_version_no_deps_test_impl(ctx):
    """One PG version, no deps → one entry with len(OPTION_SETS) targets."""
    env = unittest.begin(ctx)

    entries = _Base._build_entries(
        _base_data(["18.1"]),
        versions_deps = {},
        hub_name = "pg",
    )

    asserts.equals(env, ["18.1"], sorted(entries))

    entry = _BaseSchema.BaseEntry.decode(entries["18.1"])
    asserts.equals(env, "pg_src", entry.source_repo)
    asserts.equals(env, len(OPTION_SETS), len(entry.targets))
    asserts.equals(env, _PkgsSchema.VersionDeps.new(), entry.versions_deps)

    # entry carries a per-version source struct with hub-qualified labels
    asserts.equals(env, "18.1", entry.source.version)
    asserts.equals(env, "@pg//18.1:dir", entry.source.dir)
    asserts.equals(env, "@pg//18.1:files", entry.source.files)

    # every target has deps with sysroot=None (no deps at this version)
    for target in entry.targets:
        asserts.equals(env, None, target.deps.buildtime.sysroot)
        asserts.equals(env, [], target.deps.buildtime.packages)
        asserts.equals(env, None, target.deps.runtime.sysroot)
        asserts.equals(env, [], target.deps.runtime.packages)
        asserts.equals(env, "18.1", target.version)
        asserts.equals(
            env,
            "@pg//18.1/%s:tar" % target.option_set,
            target.artifact,
        )
        asserts.equals(env, entry.source, target.source)

    return unittest.end(env)

build_entries_one_version_no_deps_test = unittest.make(
    _build_entries_one_version_no_deps_test_impl,
)

def _build_entries_option_sets_coverage_test_impl(ctx):
    """Every option set appears exactly once per version."""
    env = unittest.begin(ctx)

    entries = _Base._build_entries(
        _base_data(["18.1"]),
        versions_deps = {},
        hub_name = "pg",
    )

    entry = _BaseSchema.BaseEntry.decode(entries["18.1"])
    option_sets_seen = sorted([t.option_set for t in entry.targets])
    asserts.equals(env, sorted(OPTION_SETS), option_sets_seen)

    return unittest.end(env)

build_entries_option_sets_coverage_test = unittest.make(
    _build_entries_option_sets_coverage_test_impl,
)

def _build_entries_bakes_qualified_deps_test_impl(ctx):
    """A version with buildtime deps → every target carries pre-qualified alias labels."""
    env = unittest.begin(ctx)

    shared_labels_by_arch = {
        "amd64": "@pgbuildtime-abc//debian/12/amd64:sysroot",
        "arm64": "@pgbuildtime-abc//debian/12/arm64:sysroot",
    }
    entries = _Base._build_entries(
        _base_data(["18.1"]),
        versions_deps = {"18.1": _buildtime_deps(shared_labels_by_arch)},
        hub_name = "mypg",
    )

    entry = _BaseSchema.BaseEntry.decode(entries["18.1"])
    for target in entry.targets:
        asserts.equals(
            env,
            "@mypg//18.1/deps/buildtime:sysroot",
            target.deps.buildtime.sysroot,
        )
        asserts.equals(
            env,
            ["@mypg//18.1/deps/buildtime/pkgs:libssl-dev"],
            target.deps.buildtime.packages,
        )

        # artifact + source labels also use the hub_name
        asserts.equals(
            env,
            "@mypg//18.1/%s:tar" % target.option_set,
            target.artifact,
        )
        asserts.equals(env, "@mypg//18.1:dir", target.source.dir)

    # entry-level versions_deps carries the per-arch @pgbuildtime labels for the
    # BUILD-file writers (`versions.bzl::write_base_version`), not for the
    # consumer surface.
    asserts.equals(
        env,
        shared_labels_by_arch,
        entry.versions_deps.buildtime.sysroot_labels_by_arch,
    )

    return unittest.end(env)

build_entries_bakes_qualified_deps_test = unittest.make(
    _build_entries_bakes_qualified_deps_test_impl,
)

def _build_entries_multiple_versions_test_impl(ctx):
    """One entry per PG version, sorted."""
    env = unittest.begin(ctx)

    entries = _Base._build_entries(
        _base_data(["16.5", "17.0", "18.1"]),
        versions_deps = {},
        hub_name = "pg",
    )

    asserts.equals(env, ["16.5", "17.0", "18.1"], sorted(entries))

    # each entry is independently decodable and points at its own version
    for v in ("16.5", "17.0", "18.1"):
        entry = _BaseSchema.BaseEntry.decode(entries[v])
        for target in entry.targets:
            asserts.equals(env, v, target.version)

    return unittest.end(env)

build_entries_multiple_versions_test = unittest.make(
    _build_entries_multiple_versions_test_impl,
)

TEST_SUITE_NAME = "base_top"

TEST_SUITE_TESTS = dict(
    build_entries_bakes_qualified_deps = build_entries_bakes_qualified_deps_test,
    build_entries_multiple_versions = build_entries_multiple_versions_test,
    build_entries_one_version_no_deps = build_entries_one_version_no_deps_test,
    build_entries_option_sets_coverage = build_entries_option_sets_coverage_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
