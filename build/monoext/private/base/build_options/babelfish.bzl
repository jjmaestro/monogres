"""
Babelfish for PostgreSQL build options.

Babelfish for PostgreSQL ships a fork of PostgreSQL
(`postgresql_modified_for_babelfish`) plus five PGXS extensions
(`babelfishpg_{tsql,tds,common,money,unit}`) under a separate repository
(`babelfish_extensions`); the extensions live under `contrib/<ext>/` and are
compiled together with PostgreSQL's standard contribs as part of the merged
source tree (see `catalog/babelfish/repo.json` `extra_sources`).

The Babelfish project ships an autoconf+make build path; the contrib Makefiles
have no Meson counterpart, so this flavor uses `pg_build_make` (autoconf-based)
rather than `pg_build` (Meson-based). The option vocabulary still mirrors
`pg.bzl` — the values are translated to autoconf flags by
`configure_args.bzl::to_configure_args` at build time.

This module wraps `pg.bzl::build_options` and applies two post-merge overrides:

- `prefix_distro = "/babelfish/<version>"` — embedded in `pg_config.h` via
  `--prefix` (the autoconf+make build does not have a separate `prefix_distro`
  option; `--prefix` is the embedded runtime path, while `make install
  DESTDIR=...` controls the install staging location independently).
- `uuid = "ossp"` (when `uuid` is in the merged options) — Babelfish documents
  `--with-uuid=ossp` in `INSTALL.md`. The override is conditional so option sets
  that omit `uuid` (e.g. `barebones`) are not affected.
"""

load("//monoext/private/base:compat.bzl", "is_compatible_with")
load(
    ":pg.bzl",
    _DEFAULT_OPTION_SET = "DEFAULT_OPTION_SET",
    _OPTION_SETS = "OPTION_SETS",
    _base_build_options = "build_options",
)

# Re-exported as-is from `pg.bzl`: the option-set composition is identical
# across these flavors; `build_options` below wraps the PG implementation to
# inject Babelfish-specific overrides.
OPTION_SETS = _OPTION_SETS
DEFAULT_OPTION_SET = _DEFAULT_OPTION_SET

_PREFIX_DISTRO = "/babelfish"

_UUID_BACKEND = "ossp"

def build_options(version, option_set, build_options_metadata, debug = False):
    """
    Computes Babelfish build options and auto-feature settings.

    Delegates to `pg.bzl` (option vocabulary is identical) and applies two
    Babelfish-specific overrides: `prefix_distro = "/babelfish/<version>"` and
    `uuid = "ossp"` (only when `uuid` is already in the resolved options;
    barebones-style sets that omit it are left unchanged).

    Args:
        version (string): Babelfish version (e.g., "4.0.0", "5.1.0").
        option_set (string): One of the predefined build option sets (e.g.
            "barebones", "full", etc).
        build_options_metadata (dict): A dictionary mapping build options to
            their compatible Babelfish version constraints spec.
        debug (bool): If `True`, prints debug messages when build options are
            incompatible with the given Babelfish version.

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

    # `uuid` is only present in option sets that include it (`minimal` and
    # above). The conditional avoids leaking `uuid = "ossp"` into `barebones`,
    # which has no UUID dependency and would otherwise pull in
    # `--with-uuid=ossp` at configure time even though the build needs no UUID
    # library.
    if "uuid" in options:
        options["uuid"] = _UUID_BACKEND

    # Force libxml on regardless of option_set: babelfishpg_tds (one of the
    # overlay contribs) includes `<libxml/uri.h>` from its `tds_int.h`, so the
    # PG core build must enable libxml to populate Makefile.global's CPPFLAGS
    # with the `-I<sysroot>/usr/include/libxml2` flag that PGXS picks up.
    # Without this, the post-install PGXS pass fails on missing libxml headers.
    options["libxml"] = "enabled"

    return options, auto_features

def build_system(_version):
    """Babelfish only ships an autoconf+make build path (PG fork + PGXS contribs)."""
    return "make"

def pg_base_version(version):
    """The upstream PostgreSQL major base Babelfish forks.

    Babelfish 5.x tracks PG 17 (where the src/bin backup tools were added); 4.x
    tracks PG 16, per the `BABEL_<v>__PG_<base>` release tags in repo.json.
    """
    return "17.0" if is_compatible_with(version, ">=5.0") else "16.0"
