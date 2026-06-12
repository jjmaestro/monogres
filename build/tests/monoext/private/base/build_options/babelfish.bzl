"""
Unit tests for monoext/private/base/build_options/babelfish.bzl.

Covers:
- each of the four predefined option sets produces the expected key options
- `auto_features = "enabled"` only for "full" (the set that includes "all")
- `auto_features = "disabled"` for the other three
- `_DEFAULT_OPTIONS` (libdir, rpath, system_tzdata) land in every set
- `prefix_distro` is injected as `/babelfish/<version>` in every set
- `uuid = "ossp"` override applies wherever `uuid` is in the resolved options
- the `uuid` override is not leaked into option sets that do not include uuid
  (the conditional avoids pulling `--with-uuid=ossp` into barebones builds)
- `injection_points` is gated `>=5.0` (PG 17 → Babelfish 5.x)
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load(
    "//monoext/private/base/build_options:babelfish.bzl",
    "DEFAULT_OPTION_SET",
    "OPTION_SETS",
    "build_options",
)
load("//tests:suite.bzl", _test_suite = "test_suite")

_EMPTY_METADATA = {}

# --- option-set coverage ---------------------------------------------------

def _barebones_set_test_impl(ctx):
    """`barebones` is minimal: only defaults + extra_version. No uuid."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("4.0", "barebones", _EMPTY_METADATA)

    asserts.equals(env, "disabled", auto_features)

    # defaults
    asserts.equals(env, "lib", options["libdir"])
    asserts.equals(env, "false", options["rpath"])
    asserts.equals(env, "/usr/share/zoneinfo", options["system_tzdata"])

    # extra_version tags the set name
    asserts.equals(env, "barebones", options["extra_version"])

    # prefix_distro is injected
    asserts.equals(env, "/babelfish/4.0", options["prefix_distro"])

    # uuid is NOT in barebones — the `uuid = "ossp"` override is conditional and
    # must not leak in.
    asserts.true(env, "uuid" not in options)

    return unittest.end(env)

barebones_set_test = unittest.make(_barebones_set_test_impl)

def _minimal_set_test_impl(ctx):
    """`minimal` adds nls, readline, ssl=openssl, uuid=ossp (Babelfish override), zlib."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("4.0", "minimal", _EMPTY_METADATA)

    asserts.equals(env, "disabled", auto_features)
    asserts.equals(env, "minimal", options["extra_version"])
    asserts.equals(env, "enabled", options["nls"])
    asserts.equals(env, "enabled", options["readline"])
    asserts.equals(env, "openssl", options["ssl"])

    # Babelfish override: uuid backend is `ossp` (PG default would be `e2fs`).
    asserts.equals(env, "ossp", options["uuid"])
    asserts.equals(env, "enabled", options["zlib"])

    return unittest.end(env)

minimal_set_test = unittest.make(_minimal_set_test_impl)

def _regular_set_test_impl(ctx):
    """`regular` extends `minimal` with icu/llvm/lz4/plpython/systemd/zstd + contrib=true."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("4.0", "regular", _EMPTY_METADATA)

    asserts.equals(env, "disabled", auto_features)
    asserts.equals(env, "regular", options["extra_version"])
    asserts.equals(env, "true", options["contrib"])
    asserts.equals(env, "enabled", options["icu"])
    asserts.equals(env, "enabled", options["llvm"])
    asserts.equals(env, "enabled", options["lz4"])
    asserts.equals(env, "enabled", options["plpython"])
    asserts.equals(env, "enabled", options["systemd"])
    asserts.equals(env, "enabled", options["zstd"])

    # uuid override carries through inheritance
    asserts.equals(env, "ossp", options["uuid"])

    return unittest.end(env)

regular_set_test = unittest.make(_regular_set_test_impl)

def _full_set_auto_features_enabled_test_impl(ctx):
    """`full` expands `all` → auto_features=enabled + DISABLED_UNLESS_EXPLICITLY_ENABLED."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("4.0", "full", _EMPTY_METADATA)

    asserts.equals(env, "enabled", auto_features)
    asserts.equals(env, "full", options["extra_version"])

    # DISABLED_UNLESS_EXPLICITLY_ENABLED:
    asserts.equals(env, "disabled", options["docs"])
    asserts.equals(env, "disabled", options["docs_pdf"])
    asserts.equals(env, "disabled", options["bsd_auth"])
    asserts.equals(env, "disabled", options["tap_tests"])
    asserts.equals(env, "disabled", options["dtrace"])
    asserts.equals(env, "false", options["cassert"])
    asserts.equals(env, "false", options["b_coverage"])

    # explicitly-enabled-in-full
    asserts.equals(env, "enabled", options["bonjour"])
    asserts.equals(env, "enabled", options["selinux"])

    # `all` itself is consumed, not emitted
    asserts.true(env, "all" not in options)

    # uuid override
    asserts.equals(env, "ossp", options["uuid"])

    return unittest.end(env)

full_set_auto_features_enabled_test = unittest.make(
    _full_set_auto_features_enabled_test_impl,
)

def _full_set_contrib_true_test_impl(ctx):
    """`full` inherits `regular`'s contrib=true (not overridden to "false")."""
    env = unittest.begin(ctx)

    options, _ = build_options("4.0", "full", _EMPTY_METADATA)

    asserts.equals(env, "true", options["contrib"])

    return unittest.end(env)

full_set_contrib_true_test = unittest.make(_full_set_contrib_true_test_impl)

# --- Babelfish-specific invariants -----------------------------------------

def _prefix_distro_per_version_test_impl(ctx):
    """`prefix_distro` is `/babelfish/<version>` for both 4.0 and 5.1."""
    env = unittest.begin(ctx)

    for version in ("4.0", "5.1"):
        options, _ = build_options(version, "barebones", _EMPTY_METADATA)
        asserts.equals(env, "/babelfish/%s" % version, options["prefix_distro"])

    return unittest.end(env)

prefix_distro_per_version_test = unittest.make(
    _prefix_distro_per_version_test_impl,
)

def _uuid_ossp_override_test_impl(ctx):
    """`uuid = "ossp"` is applied across every set that includes uuid."""
    env = unittest.begin(ctx)

    for option_set in ("minimal", "regular", "full"):
        options, _ = build_options("4.0", option_set, _EMPTY_METADATA)
        asserts.equals(
            env,
            "ossp",
            options["uuid"],
            "uuid override missing in %r set" % option_set,
        )

    return unittest.end(env)

uuid_ossp_override_test = unittest.make(_uuid_ossp_override_test_impl)

def _uuid_skipped_in_barebones_test_impl(ctx):
    """The `uuid = "ossp"` override does not leak into sets without uuid."""
    env = unittest.begin(ctx)

    # `barebones` has no UUID dependency; the conditional override must keep
    # `uuid` out of the resolved options so configure_args does not emit
    # `--with-uuid=ossp` for a build that does not need (or have) the library.
    options, _ = build_options("4.0", "barebones", _EMPTY_METADATA)
    asserts.true(env, "uuid" not in options)

    options, _ = build_options("5.1", "barebones", _EMPTY_METADATA)
    asserts.true(env, "uuid" not in options)

    return unittest.end(env)

uuid_skipped_in_barebones_test = unittest.make(
    _uuid_skipped_in_barebones_test_impl,
)

def _injection_points_gated_on_5_0_test_impl(ctx):
    """injection_points is gated `>=5.0` in repo.json (PG 17 → Babelfish 5.x)."""
    env = unittest.begin(ctx)

    metadata = {
        "injection_points": {"compatible": ">=5.0"},
    }

    # On 4.0 (PG 16 base) the metadata gates it out — never makes it into
    # `full`.
    options, _ = build_options("4.0", "full", metadata)
    asserts.true(env, "injection_points" not in options)

    # On 5.1+ (PG 17 base) it's applied by the disabled-unless-enabled pass.
    options, _ = build_options("5.1", "full", metadata)
    asserts.equals(env, "false", options["injection_points"])

    return unittest.end(env)

injection_points_gated_on_5_0_test = unittest.make(
    _injection_points_gated_on_5_0_test_impl,
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

TEST_SUITE_NAME = "babelfish"

TEST_SUITE_TESTS = dict(
    barebones_set = barebones_set_test,
    full_set_auto_features_enabled = full_set_auto_features_enabled_test,
    full_set_contrib_true = full_set_contrib_true_test,
    injection_points_gated_on_5_0 = injection_points_gated_on_5_0_test,
    minimal_set = minimal_set_test,
    option_sets_constants = option_sets_constants_test,
    prefix_distro_per_version = prefix_distro_per_version_test,
    regular_set = regular_set_test,
    uuid_ossp_override = uuid_ossp_override_test,
    uuid_skipped_in_barebones = uuid_skipped_in_barebones_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
