"""
Flavor registry for build_options.

Maps a flavor name (`metadata.flavor` in `repo.json`) to its `(OPTION_SETS,
build_options, build_system, pg_base_version)` tuple. `base.bzl` looks up the
right entry once it has parsed the catalog metadata and dispatches all
per-version-per-set option computation through it, so `base.bzl` itself stays
flavor-agnostic.

`build_system` is a callable `(version) -> "meson" | "make"` that selects which
build wrapper renders the per-(version, option_set) BUILD file: `"meson"` (uses
`pg_build` from `pg_build.bzl` wrapping `rules_foreign_cc.meson`) or `"make"`
(uses `pg_build_make` from `pg_build_make.bzl`, a hand-rolled genrule that
drives `./configure && make && make install`). It is a function (not a string)
because some flavors split per version: the `postgres` flavor routes PG <= 15.x
to make (no Meson upstream until PG 16) and PG 16.0+ to Meson. Other flavors
return a constant.
"""

load(
    ":babelfish.bzl",
    _babelfish_OPTION_SETS = "OPTION_SETS",
    _babelfish_build_options = "build_options",
    _babelfish_build_system = "build_system",
    _babelfish_pg_base_version = "pg_base_version",
)
load(
    ":ivory.bzl",
    _ivory_OPTION_SETS = "OPTION_SETS",
    _ivory_build_options = "build_options",
    _ivory_build_system = "build_system",
    _ivory_pg_base_version = "pg_base_version",
)
load(
    ":openhalo.bzl",
    _openhalo_OPTION_SETS = "OPTION_SETS",
    _openhalo_build_options = "build_options",
    _openhalo_build_system = "build_system",
    _openhalo_pg_base_version = "pg_base_version",
)
load(
    ":pg.bzl",
    _pg_OPTION_SETS = "OPTION_SETS",
    _pg_build_options = "build_options",
    _pg_build_system = "build_system",
    _pg_pg_base_version = "pg_base_version",
)

FLAVORS = {
    "babelfish": struct(
        OPTION_SETS = _babelfish_OPTION_SETS,
        build_options = _babelfish_build_options,
        build_system = _babelfish_build_system,
        pg_base_version = _babelfish_pg_base_version,
    ),
    "ivorysql": struct(
        OPTION_SETS = _ivory_OPTION_SETS,
        build_options = _ivory_build_options,
        build_system = _ivory_build_system,
        pg_base_version = _ivory_pg_base_version,
        test = True,
    ),
    "openhalo": struct(
        OPTION_SETS = _openhalo_OPTION_SETS,
        build_options = _openhalo_build_options,
        build_system = _openhalo_build_system,
        pg_base_version = _openhalo_pg_base_version,
        test = True,
    ),
    "postgres": struct(
        OPTION_SETS = _pg_OPTION_SETS,
        build_options = _pg_build_options,
        build_system = _pg_build_system,
        pg_base_version = _pg_pg_base_version,
        test = True,
    ),
}

DEFAULT_FLAVOR = "postgres"
