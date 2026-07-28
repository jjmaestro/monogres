"""
Unit tests for monoext/private/ext.bzl pure helpers:

- `_build_external(extensions, versions_deps, base_versions, hub_name)`:
  per-extension JSON entry assembly, including is_compatible filtering and the
  pre-qualification of `entry.deps.{ext_v}.{buildtime,runtime}` alias labels.
- `_build_contrib(extensions)`: per-contrib JSON entry assembly
- `_declare_build_data(ext_name, build_data, declared)`: the repo holding the
  files an extension's build stages instead of downloading them itself
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private:ext.bzl", _Ext = "testing")

# buildifier: disable=bzl-visibility
load("//monoext/private/ext:schema.bzl", _ExtSchema = "schema")

# buildifier: disable=bzl-visibility
load("//monoext/private/pkgs:schema.bzl", _PkgsSchema = "schema")
load("//tests:suite.bzl", _test_suite = "test_suite")

# --- _build_external -------------------------------------------------------

def _build_external_basic_test_impl(ctx):
    """One ext × one version × two compatible PG versions."""
    env = unittest.begin(ctx)

    bt = _PkgsSchema.DepsInfo.new(
        packages = ["libssl-dev"],
        pkgs_labels = ["@pg_pkgs//deb/libssl-dev:libssl-dev"],
        sysroot_labels_by_arch = {
            "amd64": "@pgbuildtime-bt//debian/12/amd64:sysroot",
            "arm64": "@pgbuildtime-bt//debian/12/arm64:sysroot",
        },
    )
    versions_deps = {
        "citus": {
            "13.2.0": _PkgsSchema.VersionDeps.new(buildtime = bt),
        },
    }
    extensions = {
        "citus": _ExtSchema.ExtensionEntry.new(
            ext_versions = ["13.2.0"],
            is_contrib = False,
            metadata = {},  # no compatible_with → `*` → all PG versions compatible
            source_repo = "pg_ext_src--citus",
            lock = "@pg_ext_src--citus//:lock.json",
        ),
    }

    entries = _Ext._build_external(
        extensions,
        versions_deps,
        base_versions = ["17.0", "18.1"],
        base_flavor = "postgres",
        hub_name = "pg_ext",
    )

    asserts.equals(env, ["citus"], sorted(entries))

    entry_dict = json.decode(entries["citus"])

    # simulate the lock-merge so from_dict works
    entry_dict["lock"] = {}
    entry = _ExtSchema.ExtExternalEntry.from_dict(entry_dict)

    asserts.equals(env, "citus", entry.name)
    asserts.equals(env, "pg_ext_src--citus", entry.source_repo)
    asserts.equals(env, False, entry.is_contrib)
    asserts.equals(
        env,
        {"13.2.0": ["17.0", "18.1"]},
        entry.compatible_base_versions,
    )
    asserts.equals(
        env,
        ["libssl-dev"],
        entry.versions_deps["13.2.0"].buildtime.packages,
    )
    asserts.equals(env, None, entry.versions_deps["13.2.0"].runtime)

    # deps are pre-qualified with the hub name
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/deps/buildtime:sysroot",
        entry.deps["13.2.0"].buildtime.sysroot,
    )
    asserts.equals(
        env,
        ["@pg_ext//citus/13.2.0/deps/buildtime/pkgs:libssl-dev"],
        entry.deps["13.2.0"].buildtime.packages,
    )
    asserts.equals(env, None, entry.deps["13.2.0"].runtime.sysroot)
    asserts.equals(env, [], entry.deps["13.2.0"].runtime.packages)

    # sources: one per ext_version (sorted)
    asserts.equals(env, 1, len(entry.sources))
    asserts.equals(env, "13.2.0", entry.sources[0].version)
    asserts.equals(env, "@pg_ext//citus/13.2.0:dir", entry.sources[0].dir)
    asserts.equals(env, "@pg_ext//citus/13.2.0:files", entry.sources[0].files)

    # targets: one per (ext_v × compatible base_v), artifact baked
    asserts.equals(env, 2, len(entry.targets))
    asserts.equals(env, "17.0", entry.targets[0].base_version.version)
    asserts.equals(env, "postgres~17.0", entry.targets[0].base_version.name)
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/17.0:17.0",
        entry.targets[0].artifact,
    )
    asserts.equals(env, entry.sources[0], entry.targets[0].source)
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/18.1:18.1",
        entry.targets[1].artifact,
    )

    return unittest.end(env)

build_external_basic_test = unittest.make(_build_external_basic_test_impl)

def _build_external_compatible_with_filters_test_impl(ctx):
    """`compatible_with` metadata filters the PG versions listed per ext_version."""
    env = unittest.begin(ctx)

    extensions = {
        "myext": _ExtSchema.ExtensionEntry.new(
            ext_versions = ["1.0.0"],
            is_contrib = False,
            metadata = {"compatible_with": {"postgres": {"1.0.0": "<18"}}},
            source_repo = "pg_ext_src--myext",
            lock = "@pg_ext_src--myext//:lock.json",
        ),
    }

    entries = _Ext._build_external(
        extensions,
        versions_deps = {},
        base_versions = ["16.0", "17.0", "18.1"],
        base_flavor = "postgres",
        hub_name = "pg_ext",
    )

    entry_dict = json.decode(entries["myext"])
    entry_dict["lock"] = {}
    entry = _ExtSchema.ExtExternalEntry.from_dict(entry_dict)

    # 18.1 filtered out by <18
    asserts.equals(
        env,
        {"1.0.0": ["16.0", "17.0"]},
        entry.compatible_base_versions,
    )

    return unittest.end(env)

build_external_compatible_with_filters_test = unittest.make(
    _build_external_compatible_with_filters_test_impl,
)

def _build_external_no_deps_gives_empty_deps_test_impl(ctx):
    """If the ext has no deps, deps.{ext_v}.{kind} is empty (sysroot=None)."""
    env = unittest.begin(ctx)

    extensions = {
        "noset": _ExtSchema.ExtensionEntry.new(
            ext_versions = ["0.3.0"],
            is_contrib = False,
            metadata = {},
            source_repo = "pg_ext_src--noset",
            lock = "@pg_ext_src--noset//:lock.json",
        ),
    }

    entries = _Ext._build_external(
        extensions,
        versions_deps = {},
        base_versions = ["18.1"],
        base_flavor = "postgres",
        hub_name = "pg_ext",
    )

    entry_dict = json.decode(entries["noset"])
    entry_dict["lock"] = {}
    entry = _ExtSchema.ExtExternalEntry.from_dict(entry_dict)

    asserts.equals(env, {}, entry.versions_deps)
    asserts.equals(env, None, entry.deps["0.3.0"].buildtime.sysroot)
    asserts.equals(env, [], entry.deps["0.3.0"].buildtime.packages)
    asserts.equals(env, None, entry.deps["0.3.0"].runtime.sysroot)
    asserts.equals(env, [], entry.deps["0.3.0"].runtime.packages)

    return unittest.end(env)

build_external_no_deps_gives_empty_deps_test = unittest.make(
    _build_external_no_deps_gives_empty_deps_test_impl,
)

# --- _build_contrib --------------------------------------------------------

def _build_contrib_basic_test_impl(ctx):
    """Contrib entries have ext_versions as PG-version list + pre-baked targets."""
    env = unittest.begin(ctx)

    extensions = {
        "pgcrypto": _ExtSchema.ExtensionEntry.new(
            ext_versions = ["17.0", "18.1"],
            is_contrib = True,
            metadata = {"files": {"18.1": ["lib/pgcrypto.so"]}},
        ),
    }

    entries = _Ext._build_contrib(
        extensions,
        hub_name = "pg_ext",
        base_flavor = "postgres",
    )

    asserts.equals(env, ["pgcrypto"], sorted(entries))

    entry = _ExtSchema.ExtContribEntry.decode(entries["pgcrypto"])
    asserts.equals(env, "pgcrypto", entry.name)
    asserts.equals(env, ["17.0", "18.1"], entry.ext_versions)
    asserts.equals(
        env,
        {"files": {"18.1": ["lib/pgcrypto.so"]}},
        entry.metadata,
    )
    asserts.equals(env, True, entry.is_contrib)

    # targets baked: one per PG version with hub-qualified artifact labels
    asserts.equals(env, 2, len(entry.targets))
    asserts.equals(env, "17.0", entry.targets[0].base_version.version)
    asserts.equals(
        env,
        "@pg_ext//contrib/pgcrypto/17.0:tar",
        entry.targets[0].artifact,
    )
    asserts.equals(
        env,
        "@pg_ext//contrib/pgcrypto/18.1:tar",
        entry.targets[1].artifact,
    )

    return unittest.end(env)

build_contrib_basic_test = unittest.make(_build_contrib_basic_test_impl)

# --- _declare_build_data ---------------------------------------------------

_BUILD_DATA = {
    "env": {"LINDERA_CACHE": "."},
    "files": {
        "1.5.1/dict.tar.gz": {
            "sha256": "ed3cf9e3ec8a80647f0ec783dc09dad43b8ccad2e994f5eab6ff13a41d0916c8",
            "url": "https://lindera.dev/dict.tar.gz",
        },
    },
}

def _declare_build_data_test_impl(ctx):
    """The pinned files become one repo, and labels the build can stage."""
    env = unittest.begin(ctx)

    created, declared = [], {}

    out = _Ext._declare_build_data(
        "pg_search",
        _BUILD_DATA,
        declared,
        _build_data_repo = lambda **kwargs: created.append(kwargs),
    )

    asserts.equals(env, {
        "env": {"LINDERA_CACHE": "."},
        "files": {
            "1.5.1/dict.tar.gz": "@extdata--pg_search//:1.5.1/dict.tar.gz",
        },
    }, out)

    asserts.equals(env, 1, len(created))
    asserts.equals(env, "extdata--pg_search", created[0]["name"])
    asserts.equals(env, {
        "1.5.1/dict.tar.gz": "https://lindera.dev/dict.tar.gz",
    }, created[0]["urls"])

    return unittest.end(env)

declare_build_data_test = unittest.make(_declare_build_data_test_impl)

def _declare_build_data_none_test_impl(ctx):
    """An extension whose build downloads nothing declares no repo."""
    env = unittest.begin(ctx)

    created = []

    out = _Ext._declare_build_data(
        "pg_jsonschema",
        {},
        {},
        _build_data_repo = lambda **kwargs: created.append(kwargs),
    )

    asserts.equals(env, {}, out)
    asserts.equals(env, [], created)

    return unittest.end(env)

declare_build_data_none_test = unittest.make(
    _declare_build_data_none_test_impl,
)

def _declare_build_data_shared_test_impl(ctx):
    """Every flavor reads the same catalog, so the files are fetched once."""
    env = unittest.begin(ctx)

    created, declared = [], {}

    kwargs = dict(_build_data_repo = lambda **kw: created.append(kw))

    first = _Ext._declare_build_data("pg_search", _BUILD_DATA, declared, **kwargs)
    second = _Ext._declare_build_data("pg_search", _BUILD_DATA, declared, **kwargs)

    asserts.equals(env, 1, len(created))
    asserts.equals(env, first, second)

    return unittest.end(env)

declare_build_data_shared_test = unittest.make(
    _declare_build_data_shared_test_impl,
)

TEST_SUITE_NAME = "ext_top"

TEST_SUITE_TESTS = dict(
    build_contrib_basic = build_contrib_basic_test,
    declare_build_data = declare_build_data_test,
    declare_build_data_none = declare_build_data_none_test,
    declare_build_data_shared = declare_build_data_shared_test,
    build_external_basic = build_external_basic_test,
    build_external_compatible_with_filters = build_external_compatible_with_filters_test,
    build_external_no_deps_gives_empty_deps = build_external_no_deps_gives_empty_deps_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
