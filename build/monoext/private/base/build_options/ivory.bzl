"""
IvorySQL Meson build options.

IvorySQL is a Postgres fork (Oracle-compat extensions on top of upstream PG) and
reuses PG's Meson build with a single addition (`oraport`, an integer with a
sensible default we do not need to override). With the upstream PG patches
ported (`prefix_distro`, `<EXECROOT>` CC scrub, `contrib` build option), the
option vocabulary, defaults, predefined sets and post-merge `prefix_distro`
injection mirror `pg.bzl` verbatim — so we delegate to it and only override
`prefix_distro` with the IvorySQL distro path.

Per-option compat gating (see `repo.json` `metadata.build_options`) maps PG
version constraints onto IvorySQL versions:

- `atomics`/`spinlocks` are gated `<5.0` (PG 18 dropped those Meson opts).
- `injection_points` is gated `>=4.0` (added in PG 17 → IvorySQL 4.0+).
"""

load("//monoext/private/base:compat.bzl", "is_compatible_with")
load(
    ":pg.bzl",
    _DEFAULT_OPTION_SET = "DEFAULT_OPTION_SET",
    _OPTION_SETS = "OPTION_SETS",
    _base_build_options = "build_options",
)

# Re-exported as-is from `pg.bzl`, the option-set composition is identical
# across these two flavors; `build_options` below wraps the PG implementation to
# override `prefix_distro`.
OPTION_SETS = _OPTION_SETS
DEFAULT_OPTION_SET = _DEFAULT_OPTION_SET

_PREFIX_DISTRO = "/ivorysql"

def build_options(version, option_set, build_options_metadata, debug = False):
    """
    Computes IvorySQL build options and auto-feature settings.

    Delegates to `pg.bzl` (option vocabulary is identical), parameterizing the
    IvorySQL distro path via `prefix_distro`.

    Args:
        version (string): IvorySQL major.minor version (e.g., "3.0").
        option_set (string): One of the predefined build option sets (e.g.
            "barebones", "full", etc).
        build_options_metadata (dict): A dictionary mapping build options to
            their compatible IvorySQL version constraints spec.
        debug (bool): If `True`, prints debug messages when build options are
            incompatible with the given IvorySQL version.

    Returns:
        (options, auto_features)

        A build options tuple:
            - options: Meson build options.
            - auto_features: PG `--auto-features` flag.
    """
    return _base_build_options(
        version,
        option_set,
        build_options_metadata,
        prefix_distro = _PREFIX_DISTRO,
        debug = debug,
    )

def build_system(_version):
    """IvorySQL always uses Meson (3.0+ all support it)."""
    return "meson"

def pg_base_version(version):
    """The upstream PostgreSQL major base IvorySQL forks.

    IvorySQL 4.0+ tracks PG 17 (where the src/bin backup tools pg_combinebackup
    / pg_walsummary / pg_createsubscriber were added); 3.0 tracks PG 16.
    """
    return "17.0" if is_compatible_with(version, ">=4.0") else "16.0"
