"""
Shared primitives for per-flavor build_options modules.

Each flavor module (e.g. `pg.bzl`, `ivory.bzl`) defines its own option-set
composition and flavor-specific extras, and delegates the merge logic here. The
two pieces:

- `is_compatible`: gates an option on a per-version constraint expression
  (`metadata.build_options.<option>.compatible`). Defaults to `*` when the
  metadata says nothing.
- `compute`: applies a flavor's option-set list onto its defaults, then folds
  in the `enabled-unless-disabled` and `disabled-unless-enabled` rules according
  to whether the special `"all"` token appears (which expands to Meson's
  `--auto-features=enabled`). The flavor module owns the option-set composition;
  this module owns the merge.
"""

load("//monoext/private/base:compat.bzl", "is_compatible_with")

def _is_compatible(option, version, build_options_metadata, debug = False):
    """Returns whether a build option is compatible with the given version.

    Args:
        option (string): The name of the build option to check.
        version (string): Base flavor version (e.g. "16.0", "3.0").
        build_options_metadata (dict): Mapping option → `{"compatible": spec}`
            from the flavor's `repo.json` `metadata.build_options` block.
            Missing entries default to `*` (always compatible).
        debug (bool): If `True`, prints a debug message on incompatibility.

    Returns:
        `True` if compatible, `False` otherwise.
    """
    compatible_with = build_options_metadata.get(option, {"compatible": "*"})
    version_constraints = compatible_with["compatible"]

    debug_prefix = "build option %r" % option if debug else None

    return is_compatible_with(version, version_constraints, debug_prefix)

def _compute(
        default_options,
        option_set_options,
        enabled_unless_disabled,
        disabled_unless_enabled,
        version,
        build_options_metadata,
        debug = False):
    """Merge a flavor's defaults + an option set into Meson build options.

    Args:
        default_options (dict): Base options the flavor always emits (e.g.
            `libdir`, `rpath`).
        option_set_options (list): The option-set composition for this set.
            Items are either bare strings (`"nls"` → `("nls", "enabled")`),
            `(name, value)` tuples, or `None` (skipped, used for explicit "no
            extras").
        enabled_unless_disabled (list): List of `(name, value)` tuples applied
            when `"all"` is NOT in the set — auto-features are off, but these
            are forced on unless the option set explicitly disabled them.
        disabled_unless_enabled (list): List of `(name, value)` tuples applied
            when `"all"` IS in the set — auto-features are on, but these are
            forced off unless the option set explicitly enabled them.
        version (string): Base flavor version, used for compat gating.
        build_options_metadata (dict): Per-option compat expressions.
        debug (bool): Forwards to `is_compatible`.

    Returns:
        `(options_dict, auto_features_str)`. `auto_features` is `"enabled"` if
        the special `"all"` token was in the set, `"disabled"` otherwise.
    """
    options = default_options | dict([
        option if type(option) == "tuple" else (option, "enabled")
        for option in option_set_options
        if option != None
    ])

    def is_enabled(option):
        return options.get(option, None) in ("enabled", "true")

    def is_disabled(option):
        return options.get(option, None) in ("disabled", "false")

    auto_features = "disabled"

    if "all" in options:
        auto_features = "enabled"
        options.pop("all")

        for option, value in disabled_unless_enabled:
            if (
                _is_compatible(
                    option,
                    version,
                    build_options_metadata,
                    debug,
                ) and
                not is_enabled(option)
            ):
                options[option] = value
    else:
        for option, value in enabled_unless_disabled:
            if (
                _is_compatible(
                    option,
                    version,
                    build_options_metadata,
                    debug,
                ) and
                not is_disabled(option)
            ):
                options[option] = value

    return options, auto_features

helpers = struct(
    is_compatible = _is_compatible,
    compute = _compute,
)
