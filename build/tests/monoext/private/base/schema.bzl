"""
Unit tests for build/monoext/private/base/schema.bzl.

Round-trips `BaseSource`, `BaseTarget`, and `BaseEntry` through
`json.encode(...)` → `from_dict(json.decode(...))`, including the nested
`VersionDeps`.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/base:schema.bzl", _BaseSchema = "schema")

# buildifier: disable=bzl-visibility
load("//monoext/private/pkgs:schema.bzl", _PkgsSchema = "schema")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _base_data_new_test_impl(ctx):
    env = unittest.begin(ctx)

    pkgs_group = struct(name = "postgres", versions = ["18.1"], metadata = {})
    pd = _BaseSchema.BaseData.new(
        pkgs_group = pkgs_group,
        default_version = "18.1",
        introspect_repos = {"18.1": "pg_introspect--18.1"},
        introspect_paths_repos = {"18.1": "pg_introspect_paths--18.1"},
        metadata = {"x": 1},
        source_repo = "pg_src",
        versions = ["17.0", "18.1"],
    )
    asserts.equals(env, pkgs_group, pd.pkgs_group)
    asserts.equals(env, "18.1", pd.default_version)
    asserts.equals(env, {"18.1": "pg_introspect--18.1"}, pd.introspect_repos)
    asserts.equals(
        env,
        {"18.1": "pg_introspect_paths--18.1"},
        pd.introspect_paths_repos,
    )
    asserts.equals(env, {"x": 1}, pd.metadata)
    asserts.equals(env, "pg_src", pd.source_repo)
    asserts.equals(env, ["17.0", "18.1"], pd.versions)

    return unittest.end(env)

base_data_new_test = unittest.make(_base_data_new_test_impl)

def _make_version_deps():
    bt = _PkgsSchema.DepsInfo.new(
        packages = ["libssl-dev"],
        pkgs_labels = ["@pkgs//deb/libssl-dev:libssl-dev"],
        sysroot_labels_by_arch = {
            "amd64": "@pgbuildtime-bt//debian/12/amd64:sysroot",
            "arm64": "@pgbuildtime-bt//debian/12/arm64:sysroot",
        },
    )
    return _PkgsSchema.VersionDeps.new(buildtime = bt)

def _make_source(version = "18.1"):
    return _BaseSchema.BaseSource.new("pg", version)

def _base_source_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    original = _make_source("18.1")
    decoded = _BaseSchema.BaseSource.from_dict(
        json.decode(json.encode(original)),
    )
    asserts.equals(env, original, decoded)
    asserts.equals(env, "@pg//18.1:dir", decoded.dir)
    asserts.equals(env, "@pg//18.1:files", decoded.files)

    return unittest.end(env)

base_source_roundtrip_test = unittest.make(_base_source_roundtrip_test_impl)

def _base_target_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    original = _BaseSchema.BaseTarget.new(
        hub_name = "pg",
        version = "18.1",
        option_set = "regular",
        auto_features = "disabled",
        build_options = {"libdir": "lib"},
        version_deps = _make_version_deps(),
    )
    decoded = _BaseSchema.BaseTarget.from_dict(
        json.decode(json.encode(original)),
    )
    asserts.equals(env, original, decoded)
    asserts.equals(
        env,
        "@pg//18.1/deps/buildtime:sysroot",
        decoded.deps.buildtime.sysroot,
    )
    asserts.equals(env, "@pg//18.1/regular:tar", decoded.artifact)
    asserts.equals(env, "@pg//18.1/regular:introspect", decoded.introspect)
    asserts.equals(env, "@pg//18.1:dir", decoded.source.dir)

    return unittest.end(env)

base_target_roundtrip_test = unittest.make(_base_target_roundtrip_test_impl)

def _base_entry_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    vd = _make_version_deps()
    target = _BaseSchema.BaseTarget.new(
        hub_name = "pg",
        version = "18.1",
        option_set = "regular",
        auto_features = "disabled",
        build_options = {"libdir": "lib"},
        version_deps = vd,
    )
    original = _BaseSchema.BaseEntry.new(
        hub_name = "pg",
        version = "18.1",
        source_repo = "pg_src",
        targets = [target],
        versions_deps = vd,
    )
    decoded = _BaseSchema.BaseEntry.decode(json.encode(original))

    asserts.equals(env, original.source, decoded.source)
    asserts.equals(env, original.source_repo, decoded.source_repo)
    asserts.equals(env, 1, len(decoded.targets))
    asserts.equals(env, original.targets[0], decoded.targets[0])
    asserts.equals(env, original.versions_deps, decoded.versions_deps)

    return unittest.end(env)

base_entry_roundtrip_test = unittest.make(_base_entry_roundtrip_test_impl)

def _base_entry_decode_defaults_test_impl(ctx):
    env = unittest.begin(ctx)

    e = _BaseSchema.BaseEntry.from_dict({"source_repo": "pg_src"})
    asserts.equals(env, [], e.targets)
    asserts.equals(env, None, e.source)
    asserts.equals(env, _PkgsSchema.VersionDeps.new(), e.versions_deps)

    return unittest.end(env)

base_entry_decode_defaults_test = unittest.make(
    _base_entry_decode_defaults_test_impl,
)

TEST_SUITE_NAME = "schema"

TEST_SUITE_TESTS = dict(
    base_data_new = base_data_new_test,
    base_entry_decode_defaults = base_entry_decode_defaults_test,
    base_entry_roundtrip = base_entry_roundtrip_test,
    base_source_roundtrip = base_source_roundtrip_test,
    base_target_roundtrip = base_target_roundtrip_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
