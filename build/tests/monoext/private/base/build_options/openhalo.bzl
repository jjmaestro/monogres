"""
Unit tests for monoext/private/base/build_options/openhalo.bzl.

Covers:
- each of the four predefined option sets produces the expected key options
- `auto_features = "enabled"` only for "full" (the set that includes "all")
- `auto_features = "disabled"` for the other three
- `_DEFAULT_OPTIONS` (libdir, rpath, system_tzdata) land in every set
- `prefix_distro` is injected as `/openhalo/<version>` in every set
- `uuid = "ossp"` override applies wherever `uuid` is in the resolved options
- the `uuid` override is not leaked into option sets that do not include uuid
  (the conditional avoids pulling `--with-uuid=ossp` into barebones builds)
- `zstd` is dropped from `regular` and `full` (PG 14 has no `--with-zstd`)
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load(
    "//monoext/private/base/build_options:openhalo.bzl",
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

    options, auto_features = build_options(
        "1beta1",
        "barebones",
        _EMPTY_METADATA,
    )

    asserts.equals(env, "disabled", auto_features)

    # defaults
    asserts.equals(env, "lib", options["libdir"])
    asserts.equals(env, "false", options["rpath"])
    asserts.equals(env, "/usr/share/zoneinfo", options["system_tzdata"])

    # extra_version tags the set name
    asserts.equals(env, "barebones", options["extra_version"])

    # prefix_distro is injected
    asserts.equals(env, "/openhalo/1beta1", options["prefix_distro"])

    # uuid is NOT in barebones — the `uuid = "ossp"` override is conditional and
    # must not leak in.
    asserts.true(env, "uuid" not in options)

    return unittest.end(env)

barebones_set_test = unittest.make(_barebones_set_test_impl)

def _minimal_set_test_impl(ctx):
    """`minimal` adds nls, readline, ssl=openssl, uuid=ossp (OpenHalo override), zlib."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("1beta1", "minimal", _EMPTY_METADATA)

    asserts.equals(env, "disabled", auto_features)
    asserts.equals(env, "minimal", options["extra_version"])
    asserts.equals(env, "enabled", options["nls"])
    asserts.equals(env, "enabled", options["readline"])
    asserts.equals(env, "openssl", options["ssl"])

    # OpenHalo override: uuid backend is `ossp` (PG default would be `e2fs`).
    asserts.equals(env, "ossp", options["uuid"])
    asserts.equals(env, "enabled", options["zlib"])

    return unittest.end(env)

minimal_set_test = unittest.make(_minimal_set_test_impl)

def _regular_set_test_impl(ctx):
    """`regular` extends `minimal` with icu/llvm/lz4/plpython/systemd + contrib=true.

    Notably *no* `zstd` (PG 14 has no `--with-zstd`; OpenHalo drops it).
    """
    env = unittest.begin(ctx)

    options, auto_features = build_options("1beta1", "regular", _EMPTY_METADATA)

    asserts.equals(env, "disabled", auto_features)
    asserts.equals(env, "regular", options["extra_version"])
    asserts.equals(env, "true", options["contrib"])
    asserts.equals(env, "enabled", options["icu"])
    asserts.equals(env, "enabled", options["llvm"])
    asserts.equals(env, "enabled", options["lz4"])
    asserts.equals(env, "enabled", options["plpython"])
    asserts.equals(env, "enabled", options["systemd"])

    # PG 14 has no `--with-zstd`; the option must be dropped from the merged
    # dict so the translator emits `--without-zstd` instead of `--with-zstd`.
    asserts.true(env, "zstd" not in options)

    # uuid override carries through inheritance
    asserts.equals(env, "ossp", options["uuid"])

    return unittest.end(env)

regular_set_test = unittest.make(_regular_set_test_impl)

def _full_set_auto_features_enabled_test_impl(ctx):
    """`full` expands `all` → auto_features=enabled + DISABLED_UNLESS_EXPLICITLY_ENABLED."""
    env = unittest.begin(ctx)

    options, auto_features = build_options("1beta1", "full", _EMPTY_METADATA)

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

    # PG 14 drop carries through to `full` too.
    asserts.true(env, "zstd" not in options)

    # uuid override
    asserts.equals(env, "ossp", options["uuid"])

    return unittest.end(env)

full_set_auto_features_enabled_test = unittest.make(
    _full_set_auto_features_enabled_test_impl,
)

def _full_set_contrib_true_test_impl(ctx):
    """`full` inherits `regular`'s contrib=true (not overridden to "false")."""
    env = unittest.begin(ctx)

    options, _ = build_options("1beta1", "full", _EMPTY_METADATA)

    asserts.equals(env, "true", options["contrib"])

    return unittest.end(env)

full_set_contrib_true_test = unittest.make(_full_set_contrib_true_test_impl)

# --- OpenHalo-specific invariants -----------------------------------------

def _prefix_distro_per_version_test_impl(ctx):
    """`prefix_distro` is `/openhalo/<version>` for the (single) supported version."""
    env = unittest.begin(ctx)

    options, _ = build_options("1beta1", "barebones", _EMPTY_METADATA)
    asserts.equals(env, "/openhalo/1beta1", options["prefix_distro"])

    return unittest.end(env)

prefix_distro_per_version_test = unittest.make(
    _prefix_distro_per_version_test_impl,
)

def _uuid_ossp_override_test_impl(ctx):
    """`uuid = "ossp"` is applied across every set that includes uuid."""
    env = unittest.begin(ctx)

    for option_set in ("minimal", "regular", "full"):
        options, _ = build_options("1beta1", option_set, _EMPTY_METADATA)
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
    options, _ = build_options("1beta1", "barebones", _EMPTY_METADATA)
    asserts.true(env, "uuid" not in options)

    return unittest.end(env)

uuid_skipped_in_barebones_test = unittest.make(
    _uuid_skipped_in_barebones_test_impl,
)

def _zstd_dropped_test_impl(ctx):
    """PG 14 has no `--with-zstd`; the option must be absent from every set."""
    env = unittest.begin(ctx)

    for option_set in ("barebones", "minimal", "regular", "full"):
        options, _ = build_options("1beta1", option_set, _EMPTY_METADATA)
        asserts.true(
            env,
            "zstd" not in options,
            "zstd should be dropped from %r set (PG 14 has no --with-zstd)" % option_set,
        )

    return unittest.end(env)

zstd_dropped_test = unittest.make(_zstd_dropped_test_impl)

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

TEST_SUITE_NAME = "openhalo"

TEST_SUITE_TESTS = dict(
    barebones_set = barebones_set_test,
    full_set_auto_features_enabled = full_set_auto_features_enabled_test,
    full_set_contrib_true = full_set_contrib_true_test,
    minimal_set = minimal_set_test,
    option_sets_constants = option_sets_constants_test,
    prefix_distro_per_version = prefix_distro_per_version_test,
    regular_set = regular_set_test,
    uuid_ossp_override = uuid_ossp_override_test,
    uuid_skipped_in_barebones = uuid_skipped_in_barebones_test,
    zstd_dropped = zstd_dropped_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
