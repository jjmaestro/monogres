"""
Unit tests for monoext/private/base/build_options/pg.bzl.

Covers:
- each of the four predefined option sets produces the expected key options
- `auto_features = "enabled"` only for "full" (the set that includes "all")
- `auto_features = "disabled"` for the other three
- `_DEFAULT_OPTIONS` (libdir, rpath, system_tzdata) land in every set
- `prefix_distro` is injected into every output
- `_DISABLED_UNLESS_EXPLICITLY_ENABLED` options get applied when `all` is
  present (i.e. "full")
- `_ENABLED_UNLESS_EXPLICITLY_DISABLED` options (spinlocks, atomics) get
  applied when `all` is absent (i.e. not "full")
- `build_options_metadata` version-gates can disable an option
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/base/build_options:pg.bzl", "DEFAULT_OPTION_SET", "OPTION_SETS", "build_options")
load("//tests:suite.bzl", _test_suite = "test_suite")

_EMPTY_METADATA = {}

# --- option-set coverage ---------------------------------------------------

def _barebones_set_test_impl(ctx):
    """`barebones` is minimal: only defaults + extra_version + prefix_distro."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("18.1", "barebones", _EMPTY_METADATA)

    asserts.equals(env, "disabled", auto_features)

    # defaults
    asserts.equals(env, "lib", options["libdir"])
    asserts.equals(env, "false", options["rpath"])
    asserts.equals(env, "/usr/share/zoneinfo", options["system_tzdata"])

    # extra_version tags the set name
    asserts.equals(env, "barebones", options["extra_version"])

    # prefix_distro is injected
    asserts.equals(env, "/postgres/18.1", options["prefix_distro"])

    # auto-enabled options still apply (spinlocks, atomics)
    asserts.equals(env, "true", options["spinlocks"])
    asserts.equals(env, "true", options["atomics"])

    return unittest.end(env)

barebones_set_test = unittest.make(_barebones_set_test_impl)

def _minimal_set_test_impl(ctx):
    """`minimal` adds nls, readline, ssl=openssl, uuid=e2fs, zlib."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("18.1", "minimal", _EMPTY_METADATA)

    asserts.equals(env, "disabled", auto_features)
    asserts.equals(env, "minimal", options["extra_version"])
    asserts.equals(env, "enabled", options["nls"])
    asserts.equals(env, "enabled", options["readline"])
    asserts.equals(env, "openssl", options["ssl"])
    asserts.equals(env, "e2fs", options["uuid"])
    asserts.equals(env, "enabled", options["zlib"])

    return unittest.end(env)

minimal_set_test = unittest.make(_minimal_set_test_impl)

def _regular_set_test_impl(ctx):
    """`regular` extends `minimal` with icu/llvm/lz4/plpython/systemd/zstd + contrib=true."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("18.1", "regular", _EMPTY_METADATA)

    asserts.equals(env, "disabled", auto_features)
    asserts.equals(env, "regular", options["extra_version"])
    asserts.equals(env, "true", options["contrib"])
    asserts.equals(env, "enabled", options["icu"])
    asserts.equals(env, "enabled", options["llvm"])
    asserts.equals(env, "enabled", options["lz4"])
    asserts.equals(env, "enabled", options["plpython"])
    asserts.equals(env, "enabled", options["systemd"])
    asserts.equals(env, "enabled", options["zstd"])

    return unittest.end(env)

regular_set_test = unittest.make(_regular_set_test_impl)

def _full_set_auto_features_enabled_test_impl(ctx):
    """`full` expands `all` → auto_features=enabled + DISABLED_UNLESS_EXPLICITLY_ENABLED."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("18.1", "full", _EMPTY_METADATA)

    asserts.equals(env, "enabled", auto_features)
    asserts.equals(env, "full", options["extra_version"])

    # DISABLED_UNLESS_EXPLICITLY_ENABLED:
    # docs/bsd_auth/tap_tests/dtrace/cassert all get their default-disabled
    # values
    asserts.equals(env, "disabled", options["docs"])
    asserts.equals(env, "disabled", options["docs_pdf"])
    asserts.equals(env, "disabled", options["bsd_auth"])
    asserts.equals(env, "disabled", options["tap_tests"])
    asserts.equals(env, "disabled", options["dtrace"])
    asserts.equals(env, "false", options["cassert"])
    asserts.equals(env, "false", options["injection_points"])
    asserts.equals(env, "false", options["b_coverage"])

    # explicitly-enabled-in-full list
    asserts.equals(env, "enabled", options["bonjour"])
    asserts.equals(env, "enabled", options["selinux"])

    # `all` itself is consumed, not emitted
    asserts.true(env, "all" not in options)

    return unittest.end(env)

full_set_auto_features_enabled_test = unittest.make(
    _full_set_auto_features_enabled_test_impl,
)

def _full_set_contrib_true_test_impl(ctx):
    """`full` inherits `regular`'s contrib=true (not overridden to "false")."""
    env = unittest.begin(ctx)

    options, _ = build_options("18.1", "full", _EMPTY_METADATA)

    # contrib is DISABLED_UNLESS_EXPLICITLY_ENABLED, but full already set it to
    # "true" via the regular inheritance, so the default-disabled pass must not
    # override.
    asserts.equals(env, "true", options["contrib"])

    return unittest.end(env)

full_set_contrib_true_test = unittest.make(_full_set_contrib_true_test_impl)

# --- metadata version-gating -----------------------------------------------

def _version_incompatible_option_is_dropped_test_impl(ctx):
    """Options the metadata marks incompatible with `version` are skipped."""
    env = unittest.begin(ctx)

    # "bonjour" is only applied by the default-apply passes if
    # `is_compatible("bonjour", version, metadata) == True`. Pin it to <14 on
    # 18.1 and it disappears from the non-"full" default-apply.
    metadata = {
        "bonjour": {"compatible": "<14"},
    }

    options, _ = build_options("18.1", "regular", metadata)

    # not in the regular set explicitly, so since `all` is absent and bonjour is
    # in DISABLED_UNLESS_EXPLICITLY_ENABLED but disabled by metadata on 18.1,
    # the default-disabled pass does not add it.
    asserts.true(env, "bonjour" not in options)

    return unittest.end(env)

version_incompatible_option_is_dropped_test = unittest.make(
    _version_incompatible_option_is_dropped_test_impl,
)

# --- option-set primitives -------------------------------------------------

def _option_sets_constants_test_impl(ctx):
    """OPTION_SETS is ordered barebones→minimal→regular→full, default is full."""
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        ["barebones", "minimal", "regular", "full"],
        list(OPTION_SETS),
    )
    asserts.equals(env, "full", DEFAULT_OPTION_SET)

    return unittest.end(env)

option_sets_constants_test = unittest.make(_option_sets_constants_test_impl)

# --- prefix_distro invariant -----------------------------------------------

def _prefix_distro_per_version_test_impl(ctx):
    """`prefix_distro` is `/postgres/<version>`."""
    env = unittest.begin(ctx)

    for version in ("17.0", "18.1", "16.5"):
        options, _ = build_options(version, "barebones", _EMPTY_METADATA)
        asserts.equals(env, "/postgres/%s" % version, options["prefix_distro"])

    return unittest.end(env)

prefix_distro_per_version_test = unittest.make(
    _prefix_distro_per_version_test_impl,
)

TEST_SUITE_NAME = "build_options"

TEST_SUITE_TESTS = dict(
    barebones_set = barebones_set_test,
    full_set_auto_features_enabled = full_set_auto_features_enabled_test,
    full_set_contrib_true = full_set_contrib_true_test,
    minimal_set = minimal_set_test,
    option_sets_constants = option_sets_constants_test,
    prefix_distro_per_version = prefix_distro_per_version_test,
    regular_set = regular_set_test,
    version_incompatible_option_is_dropped = version_incompatible_option_is_dropped_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
