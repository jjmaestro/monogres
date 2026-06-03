"""Tests for monoext/private/base/introspect/build_introspect.bzl"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load(
    "//monoext/private/base/introspect:build_introspect.bzl",
    BuildIntrospect = "build_introspect",
)
load("//tests:mock.bzl", "mock")
load("//tests:suite.bzl", _test_suite = "test_suite")

# pre-computed installed_paths dicts (build_path → install_path, relativized):
# used directly by get_contrib_installed_paths / get_postgres_installed_paths
# tests, and also fed into _mock_introspect_json() to build full fixtures.

_MOCK_INSTALLED_PATHS = {
    "contrib/amcheck/amcheck.so": "lib/amcheck.so",
    "contrib/hstore/hstore.control": "share/extension/hstore.control",
    "contrib/hstore/hstore.so": "lib/hstore.so",
    "contrib/pgcrypto/pgcrypto--1.0.sql": "share/extension/pgcrypto--1.0.sql",
    "contrib/pgcrypto/pgcrypto.control": "share/extension/pgcrypto.control",
    "contrib/pgcrypto/pgcrypto.so": "lib/pgcrypto.so",
    "src/backend/libpq.so": "lib/libpq.so.5",
    "src/backend/postgres": "bin/postgres",
}

# multiarch variant: Debian-style lib/{cpu}-linux-gnu/ paths.
_MOCK_INSTALLED_PATHS_MULTIARCH = {
    "contrib/example/example.so": "lib/x86_64-linux-gnu/example.so",
    "src/backend/postgres": "bin/postgres",
}

def _mock_introspect_json(installed_paths, buildsystem_files = None):
    """
    Build a minimal introspect JSON fixture from an installed_paths dict

    The fixture has the minimal structure needed by get_installed_paths():
    buildoptions (prefix), targets (bin@run), and installed. dirname of the
    bin@run filename ("/build") must be a common prefix of all build paths
    because _relativize_build_path strips it.

    Args:
        installed_paths: Dict of relativized build_path → install_path.
        buildsystem_files: Optional list of source paths (for get_contrib_names
            tests). Defaults to empty.

    Returns:
        Dict matching the meson introspect JSON schema.
    """
    result = {
        "buildoptions": [
            {
                "description": "Installation prefix",
                "machine": "host",
                "name": "prefix",
                "section": "core",
                "type": "string",
                "value": "/usr/local/pgsql",
            },
        ],
        "installed": {
            "/build/%s" % k: "/usr/local/pgsql/%s" % v
            for k, v in installed_paths.items()
        },
        "targets": [
            {
                "defined_in": "/src/meson.build",
                "filename": ["/build/postgres"],
                "id": "bin@run",
                "name": "postgres",
                "type": "executable",
            },
        ],
    }

    if buildsystem_files:
        result["buildsystem_files"] = buildsystem_files

    return result

_MOCK_INTROSPECT_JSON = _mock_introspect_json(
    _MOCK_INSTALLED_PATHS,
    buildsystem_files = [
        "/src/meson.build",
        "/src/contrib/meson.build",
        "/src/contrib/pgcrypto/meson.build",
        "/src/contrib/hstore/meson.build",
        "/src/contrib/amcheck/meson.build",
        "/src/src/backend/meson.build",
    ],
)

_MOCK_INTROSPECT_MULTIARCH = _mock_introspect_json(
    _MOCK_INSTALLED_PATHS_MULTIARCH,
)

MESON_OPTIONS_TXT = """\
option('bonjour', type: 'feature', value: 'auto',
  description: 'Bonjour support')
option('debug', type: 'boolean', value: true)
option('werror', type: 'boolean', value: false)
"""

# --- get_contrib_names -----------------------------------------------------

def _get_contrib_names_test_impl(ctx):
    """Extracts sorted contrib names from buildsystem_files."""
    env = unittest.begin(ctx)

    names = BuildIntrospect.get_contrib_names(_MOCK_INTROSPECT_JSON)

    asserts.equals(env, ["amcheck", "hstore", "pgcrypto"], names)

    return unittest.end(env)

get_contrib_names_test = unittest.make(_get_contrib_names_test_impl)

def _get_contrib_names_filters_root_meson_build_test_impl(ctx):
    """contrib/meson.build (no subdir) must be excluded."""
    env = unittest.begin(ctx)

    json = {"buildsystem_files": [
        "/src/contrib/meson.build",
    ]}
    names = BuildIntrospect.get_contrib_names(json)

    asserts.equals(env, [], names)

    return unittest.end(env)

get_contrib_names_filters_root_test = unittest.make(
    _get_contrib_names_filters_root_meson_build_test_impl,
)

def _get_contrib_names_filters_deep_paths_test_impl(ctx):
    """Paths deeper than contrib/{name}/meson.build must be excluded."""
    env = unittest.begin(ctx)

    json = {"buildsystem_files": [
        "/src/contrib/pgcrypto/subdir/meson.build",
    ]}
    names = BuildIntrospect.get_contrib_names(json)

    asserts.equals(env, [], names)

    return unittest.end(env)

get_contrib_names_filters_deep_test = unittest.make(
    _get_contrib_names_filters_deep_paths_test_impl,
)

def _get_contrib_names_empty_test_impl(ctx):
    """Empty buildsystem_files returns empty list."""
    env = unittest.begin(ctx)

    json = {"buildsystem_files": []}
    names = BuildIntrospect.get_contrib_names(json)

    asserts.equals(env, [], names)

    return unittest.end(env)

get_contrib_names_empty_test = unittest.make(_get_contrib_names_empty_test_impl)

# --- get_contrib_features --------------------------------------------------

def _get_contrib_features_override_test_impl(ctx):
    """FEATURES_OVERRIDE takes precedence over meson.build content."""
    env = unittest.begin(ctx)

    meson_build = """\
if zlib.found()
  deps += zlib
endif
"""

    result = BuildIntrospect.get_contrib_features(
        "basebackup_to_shell",
        meson_build,
    )

    asserts.equals(env, None, result)

    return unittest.end(env)

get_contrib_features_override_test = unittest.make(
    _get_contrib_features_override_test_impl,
)

def _get_contrib_features_single_dep_test_impl(ctx):
    """Single .found() call returns the feature name."""
    env = unittest.begin(ctx)

    meson_build = """\
pgcrypto_sources = files('pgcrypto.c')
if zlib.found()
  pgcrypto_deps += zlib
endif
"""
    result = BuildIntrospect.get_contrib_features("pgcrypto", meson_build)

    asserts.equals(env, "zlib", result)

    return unittest.end(env)

get_contrib_features_single_dep_test = unittest.make(
    _get_contrib_features_single_dep_test_impl,
)

def _get_contrib_features_dep_mapping_test_impl(ctx):
    """DEP_TO_FEATURE mapping: perl_dep → plperl."""
    env = unittest.begin(ctx)

    meson_build = """\
if perl_dep.found()
  do_stuff
endif
"""
    result = BuildIntrospect.get_contrib_features("bool_plperl", meson_build)

    asserts.equals(env, "plperl", result)

    return unittest.end(env)

get_contrib_features_dep_mapping_test = unittest.make(
    _get_contrib_features_dep_mapping_test_impl,
)

def _get_contrib_features_multiple_deps_test_impl(ctx):
    """Multiple .found() calls on separate lines → list."""
    env = unittest.begin(ctx)

    meson_build = """\
if zlib.found()
  deps += zlib
endif
if lz4.found()
  deps += lz4
endif
"""
    result = BuildIntrospect.get_contrib_features("test_ext", meson_build)

    asserts.equals(env, ["zlib", "lz4"], result)

    return unittest.end(env)

get_contrib_features_multiple_deps_test = unittest.make(
    _get_contrib_features_multiple_deps_test_impl,
)

def _get_contrib_features_no_deps_test_impl(ctx):
    """No .found() calls → None."""
    env = unittest.begin(ctx)

    meson_build = "sources = files('foo.c')\n"
    result = BuildIntrospect.get_contrib_features("simple_ext", meson_build)

    asserts.equals(env, None, result)

    return unittest.end(env)

get_contrib_features_no_deps_test = unittest.make(
    _get_contrib_features_no_deps_test_impl,
)

def _get_contrib_features_unknown_dep_test_impl(ctx):
    """Unknown dep name is returned as-is (no mapping)."""
    env = unittest.begin(ctx)

    meson_build = """\
if some_new_lib.found()
  deps += it
endif
"""
    result = BuildIntrospect.get_contrib_features("test_ext", meson_build)

    asserts.equals(env, "some_new_lib", result)

    return unittest.end(env)

get_contrib_features_unknown_dep_test = unittest.make(
    _get_contrib_features_unknown_dep_test_impl,
)

def _get_contrib_features_two_on_same_line_fails_test_impl(ctx):
    """Two .found() on the same line → fail."""
    env = unittest.begin(ctx)

    meson_build = """\
if zlib.found() and lz4.found()
  deps += both
endif
"""
    result = BuildIntrospect.get_contrib_features(
        "test_ext",
        meson_build,
        _fail = mock.fail,
    )

    asserts.true(env, type(result) == "string")
    asserts.true(env, "assert only one dep" in result)

    return unittest.end(env)

get_contrib_features_same_line_fails_test = unittest.make(
    _get_contrib_features_two_on_same_line_fails_test_impl,
)

# --- validate_contrib_features ---------------------------------------------

def _validate_contrib_features_known_test_impl(ctx):
    """All known features + fail_on_unknown=True → no error."""
    env = unittest.begin(ctx)

    features = {"hstore": None, "pgcrypto": "zlib", "xml2": "libxml"}
    result = BuildIntrospect.validate_contrib_features(features, True)

    asserts.equals(env, None, result)

    return unittest.end(env)

validate_contrib_features_known_test = unittest.make(
    _validate_contrib_features_known_test_impl,
)

def _validate_contrib_features_unknown_no_fail_test_impl(ctx):
    """Unknown feature + fail_on_unknown=False → no error."""
    env = unittest.begin(ctx)

    features = {"test": "totally_unknown_feature"}
    result = BuildIntrospect.validate_contrib_features(features, False)

    asserts.equals(env, None, result)

    return unittest.end(env)

validate_contrib_features_unknown_no_fail_test = unittest.make(
    _validate_contrib_features_unknown_no_fail_test_impl,
)

def _validate_contrib_features_unknown_fails_test_impl(ctx):
    """Unknown feature + fail_on_unknown=True → fail with feature name."""
    env = unittest.begin(ctx)

    features = {"test": "totally_unknown_feature"}
    result = BuildIntrospect.validate_contrib_features(
        features,
        True,
        _fail = mock.fail,
    )

    asserts.true(env, type(result) == "string")
    asserts.true(env, "totally_unknown_feature" in result)

    return unittest.end(env)

validate_contrib_features_unknown_fails_test = unittest.make(
    _validate_contrib_features_unknown_fails_test_impl,
)

def _validate_contrib_features_list_unknown_fails_test_impl(ctx):
    """Unknown feature in a list + fail_on_unknown=True → fail."""
    env = unittest.begin(ctx)

    features = {"test": ["zlib", "nonexistent_pkg"]}
    result = BuildIntrospect.validate_contrib_features(
        features,
        True,
        _fail = mock.fail,
    )

    asserts.true(env, type(result) == "string")
    asserts.true(env, "nonexistent_pkg" in result)

    return unittest.end(env)

validate_contrib_features_list_unknown_fails_test = unittest.make(
    _validate_contrib_features_list_unknown_fails_test_impl,
)

# --- get_installed_paths ---------------------------------------------------

def _get_installed_paths_test_impl(ctx):
    """Integration test: parse mock introspect JSON → relativized paths."""
    env = unittest.begin(ctx)

    result = BuildIntrospect.get_installed_paths(_MOCK_INTROSPECT_JSON)

    # build paths are relativized (stripped of /build/ prefix)
    asserts.true(env, "src/backend/postgres" in result)

    # install paths are relativized against prefix (/usr/local/pgsql/)
    asserts.equals(env, "bin/postgres", result["src/backend/postgres"])

    # contrib paths present
    asserts.equals(
        env,
        "lib/pgcrypto.so",
        result["contrib/pgcrypto/pgcrypto.so"],
    )
    asserts.equals(
        env,
        "share/extension/pgcrypto.control",
        result["contrib/pgcrypto/pgcrypto.control"],
    )

    return unittest.end(env)

get_installed_paths_test = unittest.make(_get_installed_paths_test_impl)

def _get_installed_paths_multiarch_normalization_test_impl(ctx):
    """Debian multiarch libdir (lib/{cpu}-linux-gnu/) normalized to lib/"""
    env = unittest.begin(ctx)

    result = BuildIntrospect.get_installed_paths(_MOCK_INTROSPECT_MULTIARCH)

    asserts.equals(env, "lib/example.so", result["contrib/example/example.so"])

    return unittest.end(env)

get_installed_paths_multiarch_test = unittest.make(
    _get_installed_paths_multiarch_normalization_test_impl,
)

# --- get_contrib_installed_paths / get_postgres_installed_paths ------------

def _get_contrib_installed_paths_test_impl(ctx):
    """Contrib installed paths for a known extension."""
    env = unittest.begin(ctx)

    paths = BuildIntrospect.get_contrib_installed_paths(
        _MOCK_INSTALLED_PATHS,
        "pgcrypto",
        "18.1",
    )

    asserts.equals(env, [
        "lib/pgcrypto.so",
        "share/extension/pgcrypto--1.0.sql",
        "share/extension/pgcrypto.control",
    ], paths)

    return unittest.end(env)

get_contrib_installed_paths_test = unittest.make(
    _get_contrib_installed_paths_test_impl,
)

def _get_contrib_installed_paths_nonexistent_test_impl(ctx):
    """Non-existent contrib → empty list."""
    env = unittest.begin(ctx)

    paths = BuildIntrospect.get_contrib_installed_paths(
        _MOCK_INSTALLED_PATHS,
        "nonexistent",
        "18.1",
    )

    asserts.equals(env, [], paths)

    return unittest.end(env)

get_contrib_installed_paths_nonexistent_test = unittest.make(
    _get_contrib_installed_paths_nonexistent_test_impl,
)

def _get_contrib_installed_paths_prefix_boundary_test_impl(ctx):
    """Contrib names that share a prefix must not bleed into each other.

    `hstore` and `hstore_plperl` are sibling contribs; without a trailing-slash
    boundary on the prefix match, `hstore`'s list would erroneously include
    `hstore_plperl`'s files.
    """
    env = unittest.begin(ctx)

    installed = {
        "contrib/hstore/hstore.control": "share/extension/hstore.control",
        "contrib/hstore/hstore.so": "lib/hstore.so",
        "contrib/hstore_plperl/hstore_plperl.control": "share/extension/hstore_plperl.control",
        "contrib/hstore_plperl/hstore_plperl.so": "lib/hstore_plperl.so",
        "contrib/hstore_plpython/hstore_plpython3.so": "lib/hstore_plpython3.so",
    }

    hstore = BuildIntrospect.get_contrib_installed_paths(
        installed,
        "hstore",
        "18.1",
    )
    asserts.equals(env, [
        "lib/hstore.so",
        "share/extension/hstore.control",
    ], hstore)

    hstore_plperl = BuildIntrospect.get_contrib_installed_paths(
        installed,
        "hstore_plperl",
        "18.1",
    )
    asserts.equals(env, [
        "lib/hstore_plperl.so",
        "share/extension/hstore_plperl.control",
    ], hstore_plperl)

    return unittest.end(env)

get_contrib_installed_paths_prefix_boundary_test = unittest.make(
    _get_contrib_installed_paths_prefix_boundary_test_impl,
)

def _get_contrib_installed_paths_override_test_impl(ctx):
    """CONTRIB_INSTALLED_PATHS_OVERRIDE: sepgsql has version-specific paths."""
    env = unittest.begin(ctx)

    # sepgsql < 16.7 has different paths than >= 16.7
    paths_old = BuildIntrospect.get_contrib_installed_paths(
        _MOCK_INSTALLED_PATHS,
        "sepgsql",
        "16.6",
    )

    asserts.equals(env, [
        "lib/sepgsql.so",
        "share/extension/sepgsql.sql",
    ], paths_old)

    paths_new = BuildIntrospect.get_contrib_installed_paths(
        _MOCK_INSTALLED_PATHS,
        "sepgsql",
        "16.8",
    )

    asserts.equals(env, [
        "lib/sepgsql.so",
        "share/contrib/sepgsql.sql",
    ], paths_new)

    return unittest.end(env)

get_contrib_installed_paths_override_test = unittest.make(
    _get_contrib_installed_paths_override_test_impl,
)

def _get_postgres_installed_paths_test_impl(ctx):
    """Postgres installed paths exclude contrib entries."""
    env = unittest.begin(ctx)

    paths = BuildIntrospect.get_postgres_installed_paths(_MOCK_INSTALLED_PATHS)

    asserts.equals(env, ["bin/postgres", "lib/libpq.so.5"], paths)

    return unittest.end(env)

get_postgres_installed_paths_test = unittest.make(
    _get_postgres_installed_paths_test_impl,
)

def _paths_no_overlap_test_impl(ctx):
    """Contrib and postgres paths partition the full set (no overlap)."""
    env = unittest.begin(ctx)

    postgres_paths = BuildIntrospect.get_postgres_installed_paths(
        _MOCK_INSTALLED_PATHS,
    )

    all_contrib_paths = []
    for name in ["pgcrypto", "hstore", "amcheck"]:
        all_contrib_paths.extend(
            BuildIntrospect.get_contrib_installed_paths(
                _MOCK_INSTALLED_PATHS,
                name,
                "18.1",
            ),
        )

    overlap = [p for p in postgres_paths if p in all_contrib_paths]

    asserts.equals(env, [], overlap)

    return unittest.end(env)

paths_no_overlap_test = unittest.make(_paths_no_overlap_test_impl)

# --- validate_contrib_paths ------------------------------------------------

def _validate_contrib_paths_ok_test_impl(ctx):
    """Matching names + non-empty paths → no error."""
    env = unittest.begin(ctx)

    paths = {"hstore": ["lib/hstore.so"], "pgcrypto": ["lib/pgcrypto.so"]}
    result = BuildIntrospect.validate_contrib_paths(
        paths,
        ["pgcrypto", "hstore"],
        True,
    )

    asserts.equals(env, None, result)

    return unittest.end(env)

validate_contrib_paths_ok_test = unittest.make(
    _validate_contrib_paths_ok_test_impl,
)

def _validate_contrib_paths_empty_no_fail_test_impl(ctx):
    """Empty paths + fail_on_empty=False → no error."""
    env = unittest.begin(ctx)

    paths = {"hstore": ["lib/hstore.so"], "pgcrypto": []}
    result = BuildIntrospect.validate_contrib_paths(
        paths,
        ["pgcrypto", "hstore"],
        False,
    )

    asserts.equals(env, None, result)

    return unittest.end(env)

validate_contrib_paths_empty_no_fail_test = unittest.make(
    _validate_contrib_paths_empty_no_fail_test_impl,
)

def _validate_contrib_paths_missing_fails_test_impl(ctx):
    """Missing contrib name → fail with name in message."""
    env = unittest.begin(ctx)

    paths = {"pgcrypto": ["lib/pgcrypto.so"]}
    result = BuildIntrospect.validate_contrib_paths(
        paths,
        ["pgcrypto", "hstore"],
        False,
        _fail = mock.fail,
    )

    asserts.true(env, type(result) == "string")
    asserts.true(env, "hstore" in result)

    return unittest.end(env)

validate_contrib_paths_missing_fails_test = unittest.make(
    _validate_contrib_paths_missing_fails_test_impl,
)

def _validate_contrib_paths_empty_fails_test_impl(ctx):
    """Empty paths + fail_on_empty=True → fail."""
    env = unittest.begin(ctx)

    paths = {"hstore": ["lib/hstore.so"], "pgcrypto": []}
    result = BuildIntrospect.validate_contrib_paths(
        paths,
        ["pgcrypto", "hstore"],
        True,
        _fail = mock.fail,
    )

    asserts.true(env, type(result) == "string")
    asserts.true(env, "pgcrypto" in result)

    return unittest.end(env)

validate_contrib_paths_empty_fails_test = unittest.make(
    _validate_contrib_paths_empty_fails_test_impl,
)

# --- meson_options_bzl -----------------------------------------------------

def _meson_options_bzl_test_impl(ctx):
    """Generated meson_options.bzl has correct structure and transformations."""
    env = unittest.begin(ctx)

    result = BuildIntrospect.meson_options_bzl(MESON_OPTIONS_TXT)

    # contains the generated docstring header
    asserts.true(
        env,
        "Generated by monoext/private/base/introspect. DO NOT EDIT." in result,
    )

    # contains FEATURES_TO_DEB_PKGS from metadata.bzl
    asserts.true(env, "FEATURES_TO_DEB_PKGS" in result)

    # `: ` converted to ` = `
    asserts.true(env, "type = 'feature'" in result)
    asserts.true(env, "value = 'auto'" in result)

    # true/false → True/False
    asserts.true(env, "value = True" in result)
    asserts.true(env, "value = False" in result)
    asserts.false(env, "value: true" in result)
    asserts.false(env, "value: false" in result)

    # contains the validation call
    asserts.true(env, '_validate(OPTIONS["features"])' in result)

    return unittest.end(env)

meson_options_bzl_test = unittest.make(_meson_options_bzl_test_impl)

TEST_SUITE_NAME = "build_introspect"

TEST_SUITE_TESTS = dict(
    # get_contrib_names
    get_contrib_names = get_contrib_names_test,
    get_contrib_names_filters_root = get_contrib_names_filters_root_test,
    get_contrib_names_filters_deep = get_contrib_names_filters_deep_test,
    get_contrib_names_empty = get_contrib_names_empty_test,
    # get_contrib_features
    get_contrib_features_override = get_contrib_features_override_test,
    get_contrib_features_single_dep = get_contrib_features_single_dep_test,
    get_contrib_features_dep_mapping = get_contrib_features_dep_mapping_test,
    get_contrib_features_multiple_deps = get_contrib_features_multiple_deps_test,
    get_contrib_features_no_deps = get_contrib_features_no_deps_test,
    get_contrib_features_unknown_dep = get_contrib_features_unknown_dep_test,
    get_contrib_features_same_line_fails = get_contrib_features_same_line_fails_test,
    # validate_contrib_features
    validate_contrib_features_known = validate_contrib_features_known_test,
    validate_contrib_features_unknown_no_fail = validate_contrib_features_unknown_no_fail_test,
    validate_contrib_features_unknown_fails = validate_contrib_features_unknown_fails_test,
    validate_contrib_features_list_unknown_fails = validate_contrib_features_list_unknown_fails_test,
    # get_installed_paths
    get_installed_paths = get_installed_paths_test,
    get_installed_paths_multiarch = get_installed_paths_multiarch_test,
    # get_contrib_installed_paths
    get_contrib_installed_paths = get_contrib_installed_paths_test,
    get_contrib_installed_paths_nonexistent = get_contrib_installed_paths_nonexistent_test,
    get_contrib_installed_paths_override = get_contrib_installed_paths_override_test,
    get_contrib_installed_paths_prefix_boundary = get_contrib_installed_paths_prefix_boundary_test,
    # get_postgres_installed_paths
    get_postgres_installed_paths = get_postgres_installed_paths_test,
    paths_no_overlap = paths_no_overlap_test,
    # validate_contrib_paths
    validate_contrib_paths_ok = validate_contrib_paths_ok_test,
    validate_contrib_paths_empty_no_fail = validate_contrib_paths_empty_no_fail_test,
    validate_contrib_paths_missing_fails = validate_contrib_paths_missing_fails_test,
    validate_contrib_paths_empty_fails = validate_contrib_paths_empty_fails_test,
    # meson_options_bzl
    meson_options_bzl = meson_options_bzl_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
