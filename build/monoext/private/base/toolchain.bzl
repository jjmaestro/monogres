"""
Rule for extracting Postgres-specific template variables from a Postgres build
target.

It uses `template_variable_info_rule` to expose template variables, as follows:
- `<BINARY_NAME>`: each binary under `<target>/bin/` is mapped to an uppercase
  variable of the binary name (e.g., `pg_config` → `PG_CONFIG`).
- `PG_INSTALL_DIR`: the Postgres install dir, derived from the path to
  `pg_config`.
"""

load("//toolchains:template_vars.bzl", "template_variable_info_rule")

def _pg_is_mapped(path, target):
    return "%s/bin/" % target.label.name in path

def _pg_get_name(path, _):
    return path.split("/bin/")[-1].upper()

def _pg_other_template_vars(context, _):
    # Make-built PG targets (`pg_build_make`) expose no `<target>/bin/*` paths
    # in their DefaultInfo (it carries the install tar + build log), so no PG_*
    # variables map and there is no PG_CONFIG to derive PG_INSTALL_DIR from.
    # Return no extra vars instead of failing analysis: consumers that expand
    # `$(PG_CONFIG)` against such a toolchain target then fail at THEIR site
    # with a clear "PG_CONFIG not defined" message.
    if "PG_CONFIG" not in context:
        return {}
    return {
        "PG_INSTALL_DIR": context["PG_CONFIG"].split("/bin/pg_config")[0],
    }

pg_template_variable_info = template_variable_info_rule(
    is_mapped = _pg_is_mapped,
    get_name = _pg_get_name,
    other_template_vars = _pg_other_template_vars,
)
