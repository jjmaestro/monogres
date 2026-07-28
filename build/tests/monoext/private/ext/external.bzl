"""
Unit tests for monoext/private/ext/external.bzl render helpers.

Covers every pure helper that renders a piece of the external-extension
directory tree in the @pg_ext hub:
- `_default_pg_alias`
- `_ext_root_build`, `_repo_bzl`
- `_version_build`, `_src_build`, `_src_leaf_build`
- `_pg_build`
- `_deps_kind_build`
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/ext:external.bzl", _External = "testing")
load("//tests:suite.bzl", _test_suite = "test_suite")

# --- default_pg_alias ------------------------------------------------------

def _default_pg_alias_present_test_impl(ctx):
    """With a compatible PG version, the alias points at the highest one."""
    env = unittest.begin(ctx)

    out = _External._default_pg_alias(
        alias_name = "citus",
        name = "citus",
        version = "13.2.0",
        compatible_base_versions = {"13.2.0": ["17.0", "18.1"]},
    )

    # 18.1 is the highest compatible PG version
    asserts.true(env, 'name = "citus"' in out)
    asserts.true(env, 'actual = "//citus/13.2.0/18.1:18.1"' in out)

    return unittest.end(env)

default_pg_alias_present_test = unittest.make(
    _default_pg_alias_present_test_impl,
)

def _default_pg_alias_empty_compat_test_impl(ctx):
    """No compatible PG versions → empty string (composable no-op)."""
    env = unittest.begin(ctx)

    out = _External._default_pg_alias(
        alias_name = "noset",
        name = "noset",
        version = "0.3.0",
        compatible_base_versions = {"0.3.0": []},
    )

    asserts.equals(env, "", out)

    return unittest.end(env)

default_pg_alias_empty_compat_test = unittest.make(
    _default_pg_alias_empty_compat_test_impl,
)

# --- ext_root_build --------------------------------------------------------

def _ext_root_build_test_impl(ctx):
    """{name}/BUILD.bazel: default alias + dir/files + exports_files(repo.bzl)."""
    env = unittest.begin(ctx)

    out = _External._ext_root_build(
        name = "citus",
        default_version = "13.2.0",
        compatible_base_versions = {"13.2.0": ["17.0", "18.1"]},
    )

    asserts.true(env, '"repo.bzl"' in out)
    asserts.true(env, 'name = "dir"' in out)
    asserts.true(env, 'actual = "//citus/13.2.0:dir"' in out)
    asserts.true(env, 'name = "files"' in out)
    asserts.true(env, 'actual = "//citus/13.2.0:files"' in out)

    # default alias → highest compatible pg (18.1)
    asserts.true(env, 'actual = "//citus/13.2.0/18.1:18.1"' in out)

    return unittest.end(env)

ext_root_build_test = unittest.make(_ext_root_build_test_impl)

# --- repo_bzl --------------------------------------------------------------

def _repo_bzl_test_impl(ctx):
    """repo.bzl loads source_repo and re-exports its metadata symbols."""
    env = unittest.begin(ctx)

    out = _External._repo_bzl("pg_ext_src--citus")

    asserts.true(env, '"@pg_ext_src--citus//:repo.bzl"' in out)
    for name in ("DEFAULT_VERSION", "LOCK", "METADATA", "REPO_NAME", "VERSIONS"):
        asserts.true(env, name in out, "missing %s" % name)

    return unittest.end(env)

repo_bzl_test = unittest.make(_repo_bzl_test_impl)

# --- version_build ---------------------------------------------------------

def _version_build_test_impl(ctx):
    """{name}/{version}/BUILD.bazel wraps the default alias + dir/files."""
    env = unittest.begin(ctx)

    default_alias = _External._default_pg_alias(
        alias_name = "13.2.0",
        name = "citus",
        version = "13.2.0",
        compatible_base_versions = {"13.2.0": ["17.0", "18.1"]},
    )
    out = _External._version_build("citus", "13.2.0", default_alias)

    asserts.true(env, 'actual = "//citus/13.2.0/18.1:18.1"' in out)
    asserts.true(env, 'actual = "//citus/13.2.0/src:dir"' in out)
    asserts.true(env, 'actual = "//citus/13.2.0/src:files"' in out)

    return unittest.end(env)

version_build_test = unittest.make(_version_build_test_impl)

def _version_build_pgrx_test_impl(ctx):
    """A pgrx version also gets the vendor tree, keyed pool repo -> dir."""
    env = unittest.begin(ctx)

    out = _External._version_build(
        "pg_jsonschema",
        "0.3.4",
        "",
        build_repo = "monogres",
        crates = {"crate--toml-0.9.12_spec-1.1.0": "toml-0.9.12+spec-1.1.0"},
    )

    asserts.true(
        env,
        '"@monogres//monoext/private/ext/crates:vendor.bzl"' in out,
        out,
    )
    asserts.true(env, 'name = "vendor"' in out, out)

    # The pool repo spells `+` as `_`; the vendor directory keeps the real
    # version, which is what cargo resolves against.
    asserts.true(
        env,
        '"crate--toml-0.9.12_spec-1.1.0": "toml-0.9.12+spec-1.1.0"' in out,
        out,
    )

    return unittest.end(env)

version_build_pgrx_test = unittest.make(_version_build_pgrx_test_impl)

# --- src_build -------------------------------------------------------------

def _src_build_test_impl(ctx):
    """{name}/{version}/src/BUILD.bazel: dir/files/src aliases."""
    env = unittest.begin(ctx)

    out = _External._src_build("citus", "13.2.0", "gh")

    asserts.true(env, 'actual = "//citus/13.2.0/src/gh:dir"' in out)
    asserts.true(env, 'actual = "//citus/13.2.0/src/gh:files"' in out)
    asserts.true(env, 'name = "src"' in out)
    asserts.true(env, 'actual = ":files"' in out)

    return unittest.end(env)

src_build_test = unittest.make(_src_build_test_impl)

# --- src_leaf_build --------------------------------------------------------

def _src_leaf_build_test_impl(ctx):
    """{name}/{version}/src/{source}/BUILD.bazel aliases external source labels."""
    env = unittest.begin(ctx)

    out = _External._src_leaf_build("pg_ext_src--citus", "gh", "13.2.0")

    asserts.true(env, 'actual = "@pg_ext_src--citus//13.2.0:dir"' in out)
    asserts.true(env, 'actual = "@pg_ext_src--citus//13.2.0:files"' in out)
    asserts.true(env, 'name = "gh"' in out)
    asserts.true(
        env,
        'actual = "@pg_ext_src--citus//13.2.0:13.2.0"' in out,
    )

    return unittest.end(env)

src_leaf_build_test = unittest.make(_src_leaf_build_test_impl)

# --- pg_build --------------------------------------------------------------

def _pg_build_test_impl(ctx):
    """{name}/{version}/{pg_v}/BUILD.bazel: load pgxs_build + pgxs_build(...)."""
    env = unittest.begin(ctx)

    out = _External._pg_build(
        build_repo = "monogres",
        source_repo = "pg_ext_src--citus",
        version = "13.2.0",
        base_v = "18.1",
        base_hub_name = "pg",
        bt_sysroot = "@pg_ext//citus/13.2.0/deps/buildtime:sysroot_tar",
        base_sysroot = "//_base/18.1:sysroot_tar",
        base_flavor = "postgres",
    )

    asserts.true(
        env,
        '"@monogres//monoext/private/ext/build:pgxs.bzl"' in out,
    )
    asserts.true(env, '"pgxs_build"' in out)

    # The build consumes the source repo's `:dir` straight, that being the tree
    # artifact keyed on the archive and its patches.
    asserts.true(env, "pgxs_build(" in out)
    asserts.true(env, 'name = "18.1"' in out)
    asserts.true(
        env,
        'src = "@pg_ext_src--citus//13.2.0:dir"' in out,
    )
    asserts.true(env, 'base_hub = "@pg"' in out)

    # base_version struct rendered as a dict literal
    asserts.true(env, '"name": "postgres~18.1"' in out)
    asserts.true(env, '"version": "18.1"' in out)

    # prefix_distro derived from base_flavor
    asserts.true(env, 'prefix_distro = "/postgres"' in out)

    # buildtime sysroot_tar in deps_buildtime list
    asserts.true(
        env,
        '"@pg_ext//citus/13.2.0/deps/buildtime:sysroot_tar"' in out,
    )

    # per-PG base buildtime sysroot tar threaded to pgxs_build
    asserts.true(
        env,
        'base_sysroot_tar = "//_base/18.1:sysroot_tar"' in out,
    )

    return unittest.end(env)

pg_build_test = unittest.make(_pg_build_test_impl)

def _pg_build_ivorysql_flavor_test_impl(ctx):
    """`base_flavor = "ivorysql"` renders `ivorysql~5.0` and `prefix_distro = "/ivorysql"`."""
    env = unittest.begin(ctx)

    out = _External._pg_build(
        build_repo = "monogres",
        source_repo = "ivory_ext_src--noset",
        version = "0.3.0",
        base_v = "5.0",
        base_hub_name = "ivory",
        bt_sysroot = None,
        base_sysroot = "//_base/5.0:sysroot_tar",
        base_flavor = "ivorysql",
    )

    asserts.true(env, '"name": "ivorysql~5.0"' in out)
    asserts.true(env, '"version": "5.0"' in out)
    asserts.true(env, 'base_hub = "@ivory"' in out)
    asserts.true(env, 'prefix_distro = "/ivorysql"' in out)

    return unittest.end(env)

pg_build_ivorysql_flavor_test = unittest.make(
    _pg_build_ivorysql_flavor_test_impl,
)

def _pg_build_no_sysroot_test_impl(ctx):
    """With `bt_sysroot = None`, deps_buildtime renders as an empty list."""
    env = unittest.begin(ctx)

    out = _External._pg_build(
        build_repo = "monogres",
        source_repo = "pg_ext_src--noset",
        version = "0.3.0",
        base_v = "18.1",
        base_hub_name = "pg",
        bt_sysroot = None,
        base_sysroot = "//_base/18.1:sysroot_tar",
        base_flavor = "postgres",
    )

    asserts.true(env, "deps_buildtime = []" in out)
    asserts.true(
        env,
        'base_sysroot_tar = "//_base/18.1:sysroot_tar"' in out,
    )

    return unittest.end(env)

pg_build_no_sysroot_test = unittest.make(_pg_build_no_sysroot_test_impl)

def _pg_build_pgrx_test_impl(ctx):
    """`build_system = "pgrx"` renders pgrx_build against vendor + generator."""
    env = unittest.begin(ctx)

    lock = "//catalog/extensions:pg_jsonschema/cargo/0.3.4/Cargo.lock"
    out = _External._pg_build(
        build_repo = "monogres",
        source_repo = "pg_ext_src--pg_jsonschema",
        version = "0.3.4",
        base_v = "18.1",
        base_hub_name = "pg",
        bt_sysroot = None,
        base_sysroot = "//_base/18.1:sysroot_tar",
        base_flavor = "postgres",
        build_system = "pgrx",
        ext_name = "pg_jsonschema",
        cargo = {"crates": {}, "lock": lock, "pgrx": "0.18.1"},
    )

    asserts.true(
        env,
        '"@monogres//monoext/private/ext/build:pgrx.bzl", "pgrx_build"' in out,
        out,
    )

    # The vendor tree sits one package above the per-base-version build, so the
    # three majors share the one closure.
    asserts.true(
        env,
        'vendor_tar = "//pg_jsonschema/0.3.4:vendor.tar"' in out,
        out,
    )
    asserts.true(env, 'cargo_lock = "%s"' % lock in out, out)

    # The generator built against the pgrx this version's lock pins: that pgrx
    # release owns both the `.pgrxsc` format and the SQL emitter reading it.
    asserts.true(env, 'sql_generator = "//_pgrx:pgrxsc-sql-0.18.1"' in out, out)

    # The crate version pgrx spells `@CARGO_VERSION@`, not the base version.
    asserts.true(env, 'ext_version = "0.3.4"' in out, out)

    # A single-crate source tree names no crate directory at all.
    asserts.false(env, "crate_dir" in out, out)

    return unittest.end(env)

pg_build_pgrx_test = unittest.make(_pg_build_pgrx_test_impl)

def _pg_build_pgrx_workspace_test_impl(ctx):
    """A pgrx crate below the source root names its directory to the build.

    The source root stays the cargo WORKSPACE root, so the crate's path
    dependencies and the workspace profile resolve; only cargo's cwd moves.
    """
    env = unittest.begin(ctx)

    lock = "//catalog/extensions:timescaledb_toolkit/cargo/1.24.0/Cargo.lock"
    out = _External._pg_build(
        build_repo = "monogres",
        source_repo = "pg_ext_src--timescaledb_toolkit",
        version = "1.24.0",
        base_v = "18.1",
        base_hub_name = "pg",
        bt_sysroot = None,
        base_sysroot = "//_base/18.1:sysroot_tar",
        base_flavor = "postgres",
        build_system = "pgrx",
        crate_dir = "extension",
        ext_name = "timescaledb_toolkit",
        cargo = {"crates": {}, "lock": lock, "pgrx": "0.18.1"},
    )

    asserts.true(env, 'crate_dir = "extension"' in out, out)

    return unittest.end(env)

pg_build_pgrx_workspace_test = unittest.make(
    _pg_build_pgrx_workspace_test_impl,
)

# --- deps_kind_build -------------------------------------------------------

def _deps_kind_build_test_impl(ctx):
    """{name}/{version}/deps/{kind}/BUILD.bazel: alias block for pairs."""
    env = unittest.begin(ctx)

    out = _External._deps_kind_build([
        ("sysroot", "@pg_pkgs//deb/sysroots:sysroot-abc"),
        ("libssl-dev", "@pg_pkgs//deb/libssl-dev:libssl-dev"),
    ])

    asserts.true(env, 'name = "sysroot"' in out)
    asserts.true(
        env,
        'actual = "@pg_pkgs//deb/sysroots:sysroot-abc"' in out,
    )
    asserts.true(env, 'name = "libssl-dev"' in out)

    return unittest.end(env)

deps_kind_build_test = unittest.make(_deps_kind_build_test_impl)

TEST_SUITE_NAME = "external"

TEST_SUITE_TESTS = dict(
    default_pg_alias_empty_compat = default_pg_alias_empty_compat_test,
    default_pg_alias_present = default_pg_alias_present_test,
    deps_kind_build = deps_kind_build_test,
    ext_root_build = ext_root_build_test,
    pg_build = pg_build_test,
    pg_build_ivorysql_flavor = pg_build_ivorysql_flavor_test,
    pg_build_no_sysroot = pg_build_no_sysroot_test,
    pg_build_pgrx = pg_build_pgrx_test,
    pg_build_pgrx_workspace = pg_build_pgrx_workspace_test,
    repo_bzl = repo_bzl_test,
    src_build = src_build_test,
    src_leaf_build = src_leaf_build_test,
    version_build = version_build_test,
    version_build_pgrx = version_build_pgrx_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
