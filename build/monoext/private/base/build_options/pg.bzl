"""
Postgres Meson build options

Defines default and conditional Meson build options for Postgres predefined
option sets.

For the full list of available options, see [PostgreSQL Features] and
[`meson_options.txt`].

[Postgres Features]: https://www.postgresql.org/docs/current/install-meson.html#MESON-OPTIONS-FEATURES
[`meson_options.txt`]: https://github.com/postgres/postgres/blob/master/meson_options.txt
"""

load("//monoext/private/base:compat.bzl", "is_compatible_with")
load(":helpers.bzl", _Helpers = "helpers")

# NOTE:
# Postgres embeds the install paths via a generated pg_config.h that uses the
# prefix but the prefix is the install prefix **at build time**. Since we build
# in sandboxes and will be installing the binaries at a different path, we've
# added a patch that adds a new prefix_distro build option to set the prefix of
# the "final install path in the distro".
DEFAULT_PREFIX_DISTRO = "/postgres"

_DEFAULT_OPTIONS = dict(
    # NOTE:
    # PG docs say libdir defaults to `PREFIX/lib` but the Meson build uses
    # get_option('libdir') and the Meson docs say "libdir is automatically
    # detected based on your platform". Testing on Debian amd64, libdir defaults
    # to lib64 while on arm64 is lib, so we need to pin it to lib to ensure the
    # libdir path is always the same across all platforms:
    libdir = "lib",
    rpath = "false",
    system_tzdata = "/usr/share/zoneinfo",
)

# These options are always enabled because usually it never makes sense to
# disable them
_ENABLED_UNLESS_EXPLICITLY_DISABLED = [
    ("spinlocks", "true"),
    ("atomics", "true"),
]

# These options usually only make sense on specific OSes or specific builds
# requiring the functionality (e.g. the docs or developer options) so we disable
# these by default even if auto-features is enabled and are only enabled when
# explicitly enabled.
_DISABLED_UNLESS_EXPLICITLY_ENABLED = [
    ("contrib", "false"),
    ("docs", "disabled"),
    ("docs_pdf", "disabled"),
    ("bsd_auth", "disabled"),
    ("bonjour", "disabled"),
    # --- developer options ---
    ("tap_tests", "disabled"),
    ("dtrace", "disabled"),
    ("cassert", "false"),
    ("injection_points", "false"),
    ("b_coverage", "false"),
    # --- developer options ---
]

# Predefined option sets
_OPTION_SETS_MINIMAL = [
    "nls",
    "readline",
    ("ssl", "openssl"),
    ("uuid", "e2fs"),
    "zlib",
]

_OPTION_SETS_REGULAR = _OPTION_SETS_MINIMAL + [
    ("contrib", "true"),
    "icu",
    "llvm",
    "lz4",
    "plpython",
    "systemd",
    "zstd",
]

# buildifier: leave-alone, do not sort
_OPTION_SETS = dict(
    barebones = [
        ("extra_version", "barebones"),
        None,
    ],
    minimal = [
        ("extra_version", "minimal"),
    ] + _OPTION_SETS_MINIMAL,
    regular = [
        ("extra_version", "regular"),
    ] + _OPTION_SETS_REGULAR,
    full = [
        ("extra_version", "full"),
        "all",
        "bonjour",
        "selinux",  # in 16.0 it's not 'auto' so it has to be enabled explicitly
    ] + _OPTION_SETS_REGULAR,
)

# we only want the sizes to be used publicly, the mapping remains private
OPTION_SETS = _OPTION_SETS.keys()
DEFAULT_OPTION_SET = OPTION_SETS[-1]

def build_options(
        version,
        option_set,
        build_options_metadata,
        prefix_distro = DEFAULT_PREFIX_DISTRO,
        debug = False):
    """
    Computes Postgres build options and auto-feature settings.

    Args:
        version (string): Postgres major.minor version (e.g., "16.0").
        option_set (string): One of the predefined build option sets (e.g.
            "barebones", "full", etc).
        build_options_metadata (dict): A dictionary mapping Postgres build
            options to their compatible PG version constraints spec.
        prefix_distro (str): The base prefix path for the distro install
            (defaults to `DEFAULT_PREFIX_DISTRO`).
        debug (bool): If `True`, prints debug messages when build options are
            incompatible with the given Postgre version.

    Returns:
        (options, auto_features)

        A build options tuple:
            - options: Meson build options.
            - auto_features: PG `--auto-features flag.
    """
    if option_set not in OPTION_SETS:
        fail("Invalid option set: %r" % option_set)

    options, auto_features = _Helpers.compute(
        default_options = _DEFAULT_OPTIONS,
        option_set_options = _OPTION_SETS[option_set],
        enabled_unless_disabled = _ENABLED_UNLESS_EXPLICITLY_DISABLED,
        disabled_unless_enabled = _DISABLED_UNLESS_EXPLICITLY_ENABLED,
        version = version,
        build_options_metadata = build_options_metadata,
        debug = debug,
    )

    options["prefix_distro"] = "%s/%s" % (prefix_distro, version)

    return options, auto_features

def build_system(version):
    """Per-version build-system selector for the `postgres` flavor.

    PG <= 15.x predates the Meson build (introduced in PG 16) and is only
    buildable via autoconf+make. Route those versions through `pg_build_make`;
    everything else stays on Meson `pg_build`.
    """
    return "make" if is_compatible_with(version, "<16.0") else "meson"

def pg_base_version(version):
    """The upstream PostgreSQL major.minor a flavor is built on.

    For the `postgres` flavor the base IS the version itself. Flavors that fork
    a specific PostgreSQL release override this to report that upstream base,
    which gates PG-version-specific tooling (e.g. the PG17 src/bin backup tools)
    on the real PostgreSQL version rather than the flavor's own version number.
    """
    return version
