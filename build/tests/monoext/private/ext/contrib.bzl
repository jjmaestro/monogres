"""
Unit tests for monoext/private/ext/contrib.bzl render helpers.

Covers:
- `_contrib_root_build(name, default_base_version)`: contrib/{name}/BUILD.bazel
- `_contrib_repo_bzl(sorted_base_versions, default_base_version, metadata)`
- `_contrib_pg_build(build_repo, name, base_hub_name, base_version,
  strip_prefix, files)`
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/ext:contrib.bzl", _Contrib = "testing")
load("//tests:suite.bzl", _test_suite = "test_suite")

# --- contrib_root_build ----------------------------------------------------

def _contrib_root_build_test_impl(ctx):
    """contrib/{name}/BUILD.bazel: default-PG alias + files + repo.bzl export."""
    env = unittest.begin(ctx)

    out = _Contrib._contrib_root_build("pgcrypto", "18.1")

    asserts.true(env, '"repo.bzl"' in out)
    asserts.true(env, 'name = "pgcrypto"' in out)
    asserts.true(env, 'actual = "//contrib/pgcrypto/18.1:tar"' in out)
    asserts.true(env, 'name = "files"' in out)
    asserts.true(env, 'actual = "//contrib/pgcrypto/18.1:files"' in out)

    return unittest.end(env)

contrib_root_build_test = unittest.make(_contrib_root_build_test_impl)

# --- contrib_repo_bzl ------------------------------------------------------

def _contrib_repo_bzl_test_impl(ctx):
    """contrib/{name}/repo.bzl bakes VERSIONS + DEFAULT_VERSION + METADATA."""
    env = unittest.begin(ctx)

    out = _Contrib._contrib_repo_bzl(
        sorted_base_versions = ["17.0", "18.1"],
        default_base_version = "18.1",
        metadata = {"files": {"18.1": ["lib/pgcrypto.so"]}},
    )

    asserts.true(env, "VERSIONS = " in out)
    asserts.true(env, '"17.0"' in out)
    asserts.true(env, '"18.1"' in out)
    asserts.true(env, 'DEFAULT_VERSION = "18.1"' in out)
    asserts.true(env, "METADATA = " in out)
    asserts.true(env, '"lib/pgcrypto.so"' in out)

    return unittest.end(env)

contrib_repo_bzl_test = unittest.make(_contrib_repo_bzl_test_impl)

# --- contrib_pg_build ------------------------------------------------------

def _contrib_pg_build_test_impl(ctx):
    """contrib/{name}/{pg}/BUILD.bazel: declare_outputs → mtree_spec → mtree_mutate → tar."""
    env = unittest.begin(ctx)

    out = _Contrib._contrib_pg_build(
        build_repo = "monogres",
        name = "pgcrypto",
        base_hub_name = "pg",
        base_version = "18.1",
        strip_prefix = "contrib/pgcrypto/18.1/tar/files",
        files = ["lib/pgcrypto.so", "share/extension/pgcrypto.control"],
    )

    # loads
    asserts.true(env, '"@tar.bzl//tar:mtree.bzl"' in out)
    asserts.true(env, '"@tar.bzl//tar:tar.bzl"' in out)
    asserts.true(
        env,
        '"@monogres//utils:declare_outputs.bzl"' in out,
    )

    # declare_outputs → src from the SDK tree @pg//18.1/full:tar.dev (the full
    # `meson install` carrying the headers a contrib extension compiles
    # against).
    asserts.true(env, "declare_outputs(" in out)
    asserts.true(env, 'name = "files"' in out)
    asserts.true(env, 'src = "@pg//18.1/full:tar.dev"' in out)
    asserts.true(env, '"lib/pgcrypto.so"' in out)

    # mtree spec + mutate + tar chain
    asserts.true(env, "mtree_spec(" in out)
    asserts.true(env, "mtree_mutate(" in out)
    asserts.true(env, "tar(" in out)
    asserts.true(env, 'name = "tar"' in out)
    asserts.true(env, 'out = "pgcrypto.tar"' in out)
    asserts.true(env, 'strip_prefix = "contrib/pgcrypto/18.1/tar/files"' in out)
    asserts.true(env, 'ownername = "postgres"' in out)

    return unittest.end(env)

contrib_pg_build_test = unittest.make(_contrib_pg_build_test_impl)

TEST_SUITE_NAME = "contrib"

TEST_SUITE_TESTS = dict(
    contrib_pg_build = contrib_pg_build_test,
    contrib_repo_bzl = contrib_repo_bzl_test,
    contrib_root_build = contrib_root_build_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
