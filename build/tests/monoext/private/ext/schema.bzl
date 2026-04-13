"""
Unit tests for build/monoext/private/ext/schema.bzl.

Covers `ExtData`, `ExtensionEntry`, and round-trips both entry variants
(`ExtExternalEntry`, `ExtContribEntry`) through JSON. External entries do not
round-trip via a `.decode()` helper; the lock field is merged into the decoded
dict by `ext/hub.bzl::_impl()`; the test simulates that merge explicitly.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/ext:schema.bzl", _ExtSchema = "schema")

# buildifier: disable=bzl-visibility
load("//monoext/private/pkgs:schema.bzl", _PkgsSchema = "schema")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _ext_data_new_test_impl(ctx):
    env = unittest.begin(ctx)

    ed = _ExtSchema.ExtData.new(
        pkgs_groups = [struct(
            name = "citus",
            versions = ["13.2.0"],
            metadata = {},
        )],
        extensions = {
            "citus": _ExtSchema.ExtensionEntry.new(
                ext_versions = ["13.2.0"],
                is_contrib = False,
                metadata = {},
                source_repo = "pg_ext_src--citus",
                lock = "@pg_ext_src--citus//:lock.json",
            ),
        },
    )
    asserts.equals(env, 1, len(ed.pkgs_groups))
    asserts.equals(env, False, ed.extensions["citus"].is_contrib)
    asserts.equals(
        env,
        "@pg_ext_src--citus//:lock.json",
        ed.extensions["citus"].lock,
    )

    return unittest.end(env)

ext_data_new_test = unittest.make(_ext_data_new_test_impl)

def _ext_data_defaults_test_impl(ctx):
    env = unittest.begin(ctx)

    ed = _ExtSchema.ExtData.new()
    asserts.equals(env, [], ed.pkgs_groups)
    asserts.equals(env, {}, ed.extensions)

    return unittest.end(env)

ext_data_defaults_test = unittest.make(_ext_data_defaults_test_impl)

def _extension_entry_contrib_test_impl(ctx):
    env = unittest.begin(ctx)

    e = _ExtSchema.ExtensionEntry.new(
        ext_versions = ["18.1"],
        is_contrib = True,
        metadata = {"files": {}},
    )
    asserts.equals(env, True, e.is_contrib)
    asserts.equals(env, None, e.source_repo)
    asserts.equals(env, None, e.lock)

    return unittest.end(env)

extension_entry_contrib_test = unittest.make(_extension_entry_contrib_test_impl)

def _make_version_deps():
    return _PkgsSchema.VersionDeps.new(
        buildtime = _PkgsSchema.DepsInfo.new(
            packages = ["libssl-dev"],
            pkgs_labels = ["@pkgs//deb/libssl-dev:libssl-dev"],
            sysroot_labels_by_arch = {
                "amd64": "@pgbuildtime-bt//debian/12/amd64:sysroot",
                "arm64": "@pgbuildtime-bt//debian/12/arm64:sysroot",
            },
        ),
    )

def _make_external_target(ext_v = "13.2.0", base_v = "18.1"):
    return _ExtSchema.ExtExternalTarget.new(
        ext_hub_name = "pg_ext",
        ext_name = "citus",
        ext_version = ext_v,
        base_v = base_v,
        version_deps = _make_version_deps(),
    )

def _ext_external_target_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    original = _make_external_target()
    decoded = _ExtSchema.ExtExternalTarget.from_dict(
        json.decode(json.encode(original)),
    )
    asserts.equals(env, original, decoded)
    asserts.equals(env, "@pg_ext//citus/13.2.0/18.1:18.1", decoded.artifact)
    asserts.equals(env, "postgres~18.1", decoded.base_version.name)
    asserts.equals(env, "@pg_ext//citus/13.2.0:dir", decoded.source.dir)

    return unittest.end(env)

ext_external_target_roundtrip_test = unittest.make(
    _ext_external_target_roundtrip_test_impl,
)

def _ext_contrib_target_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    original = _ExtSchema.ExtContribTarget.new("pg_ext", "pgcrypto", "18.1")
    decoded = _ExtSchema.ExtContribTarget.from_dict(
        json.decode(json.encode(original)),
    )
    asserts.equals(env, original, decoded)
    asserts.equals(env, "@pg_ext//contrib/pgcrypto/18.1:tar", decoded.artifact)
    asserts.equals(env, "postgres~18.1", decoded.base_version.name)

    return unittest.end(env)

ext_contrib_target_roundtrip_test = unittest.make(
    _ext_contrib_target_roundtrip_test_impl,
)

def _ext_external_entry_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    vd = _make_version_deps()
    original = _ExtSchema.ExtExternalEntry.new(
        ext_hub_name = "pg_ext",
        ext_name = "citus",
        ext_versions = ["13.2.0"],
        compatible_base_versions = {"13.2.0": ["17.0", "18.1"]},
        source_repo = "pg_ext_src--citus",
        ext_versions_deps = {"13.2.0": vd},
    )

    # Simulate what ext/hub.bzl::_impl() does:
    entry_dict = json.decode(json.encode(original))
    entry_dict["lock"] = {"13.2.0": {"source": "gh"}}

    decoded = _ExtSchema.ExtExternalEntry.from_dict(entry_dict)
    asserts.equals(env, original.name, decoded.name)
    asserts.equals(env, original.source_repo, decoded.source_repo)
    asserts.equals(
        env,
        original.compatible_base_versions,
        decoded.compatible_base_versions,
    )
    asserts.equals(
        env,
        original.versions_deps["13.2.0"],
        decoded.versions_deps["13.2.0"],
    )
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/deps/buildtime:sysroot",
        decoded.deps["13.2.0"].buildtime.sysroot,
    )
    asserts.equals(
        env,
        ["@pg_ext//citus/13.2.0/deps/buildtime/pkgs:libssl-dev"],
        decoded.deps["13.2.0"].buildtime.packages,
    )
    asserts.equals(env, {"13.2.0": {"source": "gh"}}, decoded.lock)
    asserts.equals(env, 1, len(decoded.sources))
    asserts.equals(env, "@pg_ext//citus/13.2.0:dir", decoded.sources[0].dir)
    asserts.equals(env, 2, len(decoded.targets))
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/17.0:17.0",
        decoded.targets[0].artifact,
    )
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/18.1:18.1",
        decoded.targets[1].artifact,
    )

    return unittest.end(env)

ext_external_entry_roundtrip_test = unittest.make(
    _ext_external_entry_roundtrip_test_impl,
)

def _ext_contrib_entry_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    original = _ExtSchema.ExtContribEntry.new(
        ext_hub_name = "pg_ext",
        ext_name = "pg_trgm",
        ext_versions = ["17.0", "18.1"],
        metadata = {"files": {"18.1": ["lib/foo.so"]}},
    )
    decoded = _ExtSchema.ExtContribEntry.decode(json.encode(original))
    asserts.equals(env, original, decoded)
    asserts.equals(env, "pg_trgm", decoded.name)
    asserts.equals(env, 2, len(decoded.targets))
    asserts.equals(
        env,
        "@pg_ext//contrib/pg_trgm/17.0:tar",
        decoded.targets[0].artifact,
    )

    return unittest.end(env)

ext_contrib_entry_roundtrip_test = unittest.make(
    _ext_contrib_entry_roundtrip_test_impl,
)

TEST_SUITE_NAME = "schema"

TEST_SUITE_TESTS = dict(
    ext_contrib_entry_roundtrip = ext_contrib_entry_roundtrip_test,
    ext_contrib_target_roundtrip = ext_contrib_target_roundtrip_test,
    ext_data_defaults = ext_data_defaults_test,
    ext_data_new = ext_data_new_test,
    ext_external_entry_roundtrip = ext_external_entry_roundtrip_test,
    ext_external_target_roundtrip = ext_external_target_roundtrip_test,
    extension_entry_contrib = extension_entry_contrib_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
