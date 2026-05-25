"""
Flavor registry for build_options.

Maps a flavor name (`metadata.flavor` in `repo.json`) to its `(OPTION_SETS,
build_options, pg_base_version)` tuple. `base.bzl` looks up the right entry once
it has parsed the catalog metadata and dispatches all per-version-per-set option
computation through it, so `base.bzl` itself stays flavor-agnostic.
"""

load(
    ":pg.bzl",
    _pg_OPTION_SETS = "OPTION_SETS",
    _pg_build_options = "build_options",
    _pg_pg_base_version = "pg_base_version",
)

FLAVORS = {
    "postgres": struct(
        OPTION_SETS = _pg_OPTION_SETS,
        build_options = _pg_build_options,
        pg_base_version = _pg_pg_base_version,
        test = True,
    ),
}

DEFAULT_FLAVOR = "postgres"
