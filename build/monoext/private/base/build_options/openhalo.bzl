"""
OpenHalo build options.

OpenHalo is a PG 14.18 fork (HaloTech-Co-Ltd/openHalo) that adds MySQL wire-
protocol + dialect compatibility. The MySQL adapter is inline in
`src/backend/adapter/mysql/` and the helper extension `aux_mysql` is shipped in
upstream `contrib/`, so the source tree is self-contained — no sibling tarball
or `extra_sources` are needed.

OpenHalo ships only an autoconf+make build path; this flavor uses
`pg_build_make` (the make wrapper) and the option vocabulary defined by
`pg.bzl`, with three post-merge adjustments:

- `prefix_distro = "/openhalo/<version>"` — embedded in `pg_config.h` via
  `--prefix` (the autoconf+make build does not have a separate `prefix_distro`
  option; `--prefix` is the embedded runtime path, while `make install
  DESTDIR=...` controls the install staging location independently).
- `uuid = "ossp"` (when `uuid` is in the merged options) — OpenHalo's upstream
  README documents `--with-uuid=ossp` as mandatory. The override is conditional
  so option sets that omit `uuid` (e.g. `barebones`) are not affected.
- `zstd` is dropped from the merged options. PG 14 has no `--with-zstd` flag
  (added in PG 15); `to_configure_args` enumerates the full known boolean option
  set and emits `--without-X` for any option absent from the merged dict, so
  popping `zstd` here yields `--without-zstd` at configure time — which
  OpenHalo's autoconf surfaces as a benign unrecognized-option warning, whereas
  leaving `zstd = "enabled"` in `regular`/`full` would emit `--with-zstd` and
  fail. Per-option compat gating via `metadata.build_options.compatible` does
  not cover this case: `zstd` is in `pg.bzl::_OPTION_SETS_REGULAR` directly, and
  the compat check in `helpers.compute()` only runs against
  `_DISABLED_UNLESS_EXPLICITLY_ENABLED` / `_ENABLED_UNLESS_EXPLICITLY_DISABLED`.
"""

load(
    ":pg.bzl",
    _DEFAULT_OPTION_SET = "DEFAULT_OPTION_SET",
    _OPTION_SETS = "OPTION_SETS",
    _base_build_options = "build_options",
)

# Re-exported as-is from `pg.bzl`: the option-set composition is identical
# across these flavors; `build_options` below wraps the PG implementation to
# inject OpenHalo-specific overrides.
OPTION_SETS = _OPTION_SETS
DEFAULT_OPTION_SET = _DEFAULT_OPTION_SET

_PREFIX_DISTRO = "/openhalo"

_UUID_BACKEND = "ossp"

# Options dropped because OpenHalo's PG 14 autoconf surface predates them. When
# more OpenHalo versions land on a newer PG base, gate this list per version
# (e.g. via `build_options_metadata`) instead of dropping unconditionally.
_DROP_PG14_INCOMPATIBLE = ("zstd",)

def build_options(version, option_set, build_options_metadata, debug = False):
    """
    Computes OpenHalo build options and auto-feature settings.

    Delegates to `pg.bzl` (option vocabulary is identical) and applies three
    OpenHalo-specific adjustments: drop PG-14-incompatible options (currently
    `zstd`), inject `prefix_distro = "/openhalo/<version>"`, and inject `uuid =
    "ossp"` when `uuid` is already in the resolved options (barebones-style sets
    that omit it are left unchanged).

    Args:
        version (string): OpenHalo version (e.g. "1.0").
        option_set (string): One of the predefined build option sets (e.g.
            "barebones", "full", etc).
        build_options_metadata (dict): A dictionary mapping build options to
            their compatible OpenHalo version constraints spec.
        debug (bool): If `True`, prints debug messages when build options are
            incompatible with the given OpenHalo version.

    Returns:
        (options, auto_features)

        A build options tuple:
            - options: Build option values (Meson-style names; translated to
              autoconf flags downstream by `configure_args.to_configure_args`).
            - auto_features: PG `--auto-features` flag.
    """
    options, auto_features = _base_build_options(
        version,
        option_set,
        build_options_metadata,
        prefix_distro = _PREFIX_DISTRO,
        debug = debug,
    )

    for opt in _DROP_PG14_INCOMPATIBLE:
        options.pop(opt, None)

    # `uuid` is only present in option sets that include it (`minimal` and
    # above). The conditional avoids leaking `uuid = "ossp"` into `barebones`,
    # which has no UUID dependency and would otherwise pull in
    # `--with-uuid=ossp` at configure time even though the build needs no UUID
    # library.
    if "uuid" in options:
        options["uuid"] = _UUID_BACKEND

    return options, auto_features

def build_system(_version):
    """OpenHalo only ships an autoconf+make build path."""
    return "make"

def pg_base_version(_version):
    """OpenHalo forks PostgreSQL 14, which predates the PG17 src/bin backup tools."""
    return "14.0"
