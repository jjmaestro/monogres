"""
Repo name derivation and label formatting for the monoext module extension.

The monoext module extension creates a constellation of repos derived from a
single `hub_name` root (the `tag.name` value). This module centralizes:

1. The repo-naming conventions: role suffixes (`_src`, `_ext`, `_pkgs`, `_deb`)
   joined by `_`, instance suffixes joined by `INSTANCE_SEP` (`--`).
2. The `bind()` helper for f-string-style label formatting.

Label patterns are written inline at call sites using `bind()`:

    f = bind(hub = hub_name, v = version, opt = option_set) artifact =
    f("@{hub}//{v}/{opt}:tar")

Public repo names (consumers reference these in `use_repo(...)`):

- `@{hub}`            : base hub
- `@{hub}_ext`        : extensions hub
- `@{hub}_pkgs`       : shared package pool

Internal repo names (created by `create_*` helpers, not exposed):

- `@{hub}_src`             : base source index (lazy per-version downloads)
- `@{hub}_src-{v}`         : per-version base source repo
- `@{hub}_introspect--{v}`       : per-version PG introspect (Layer 2: features
  + meson options; introspect is currently PG-specific)
- `@{hub}_introspect_paths--{v}` : per-version PG introspect (Layer 1: paths
  only)
- `@{hub}_src--{ext}`            : per-extension source (off ext hub)
- `@{hub}_deb`             : internal deb_translate_lock (off pkgs hub)

Hub-independent internal repos (one per module extension evaluation, NOT one per
hub, so every hub shares them):

- `@crate--{crate}-{v}`    : one crates.io crate release (crate pool). A crate
  release is the same artifact whatever hub pins it, and the closures overlap
  heavily, so the pool hangs off no hub at all.
- `@crate_git--{repo}-{rev}`     : the crates one git revision publishes (crate
  pool). A revision holds a whole cargo workspace, so it is fetched once and
  keyed by the commit rather than by any one crate in it.

Suffix conventions:

- **Role suffix** (`_src`, `_ext`, `_pkgs`, `_deb`): one per parent, no
  instance variant. Joined with a single `_`.
- **Instance suffix** (version, extension name): many per parent. Joined
  with `INSTANCE_SEP` (`--`), unambiguous even when the instance contains a
  single `-` (e.g. Debian version `1:14.0.6-12`).
- The per-version base source repo uses a single `-` because
  `download_archives` owns that naming convention, not this module.
"""

INSTANCE_SEP = "--"

def bind(**ctx):
    """Create a label formatter with a fixed context.

    Returns a function `f(template)` that calls `template.format(**ctx)`. Extra
    keys in `ctx` that don't appear in a template are silently ignored.

    Usage:
        f = bind(hub = "pg", v = "18.1", opt = "full")
        f("@{hub}//{v}/{opt}:tar")    # -> "@pg//18.1/full:tar"
        f("@{hub}//{v}:dir")          # -> "@pg//18.1:dir" (opt ignored)
    """

    def _f(template):
        return template.format(**ctx)

    return _f

repo_names = struct(
    INSTANCE_SEP = INSTANCE_SEP,
    ext_hub = lambda hub: "{hub}_ext".format(hub = hub),
    pkgs_hub = lambda hub: "{hub}_pkgs".format(hub = hub),
    base_src = lambda hub: "{hub}_src".format(hub = hub),
    base_src_version = lambda hub, v: "{hub}_src-{v}".format(hub = hub, v = v),
    pg_introspect = lambda hub, v: "{hub}_introspect{sep}{v}".format(
        hub = hub,
        sep = INSTANCE_SEP,
        v = v,
    ),
    pg_introspect_paths = lambda hub, v: "{hub}_introspect_paths{sep}{v}".format(
        hub = hub,
        sep = INSTANCE_SEP,
        v = v,
    ),
    ext_src = lambda hub, ext: "{hub}_src{sep}{ext}".format(
        hub = hub,
        sep = INSTANCE_SEP,
        ext = ext,
    ),
    deb_repo = lambda hub: "{hub}_deb".format(hub = hub),
    # A repo name may not contain `+`, which a semver version can (build
    # metadata, e.g. `toml 0.9.12+spec-1.1.0`), so it is spelled `_` here. The
    # crate's directory in a vendor tree keeps the real version, so the two are
    # carried side by side rather than derived from each other.
    crate = lambda crate, v: "crate{sep}{crate}-{v}".format(
        sep = INSTANCE_SEP,
        crate = crate,
        v = v,
    ).replace("+", "_"),
    # Keyed on the revision archive's top-level directory, which forges name
    # `{repo}-{rev}`: unique per commit by construction, and the one identifier
    # the crates in it already share.
    git_crates = lambda strip_prefix: "crate_git{sep}{prefix}".format(
        sep = INSTANCE_SEP,
        prefix = strip_prefix,
    ),
)
