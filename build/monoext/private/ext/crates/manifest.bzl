"""
Turn a git checkout's workspace members into standalone crate manifests.

A crate taken from a git repository is usually a member of a cargo workspace,
and a member may leave fields out of its own manifest to inherit them from the
workspace root instead: `serde.workspace = true` in place of a version
requirement, `version.workspace = true` in place of a version. Cargo resolves
those against the root when it reads the member.

The vendor tree the pool assembles has no root to resolve against. It is a flat
directory of `<crate>-<version>/` siblings (see `vendor.bzl`), so a member that
inherits lands there with nothing above it and cargo cannot read its manifest at
all. `cargo vendor` sidesteps this by writing NORMALIZED manifests, every
inherited field already substituted; the pool extracts commit archives as the
forge serves them, so it has to do that substitution itself.

This is that substitution, and deliberately nothing more. In particular a `path`
dependency is left alone even though a flat vendor tree never satisfies one,
because cargo resolves a dependency of a non-local package through the replaced
source by version and ignores its `path`: `tantivy-columnar` asks for `{ version
= "0.6", path = "../stacker" }` and builds. By the same token a vendored repo
root keeps its `[workspace]` table, whose `members` name directories that the
pool files as siblings rather than children. Cargo does no workspace processing
for a package it did not take from a path, which is also why every vendored
crate can sit inside the extension's own workspace tree without becoming a
member of it. Inheritance is the one construct with no such fallback: there is
no version requirement to resolve instead.
"""

load("@toml.bzl//:toml.bzl", "toml")

# The key a member sets to `true` to inherit, in each of the three places it can
# appear: as the value of a `[package]` field, as the value of a dependency, and
# as the whole body of a table (`[lints]`).
_WORKSPACE = "workspace"

# The dependency tables a manifest may carry. Each may also appear under a
# `[target.<cfg>]` section, and inheritance works the same in all of them.
_DEP_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")

# The tables inherited whole, as `[<table>] workspace = true`, rather than field
# by field. `badges` is long deprecated but still accepted by cargo.
_INHERITED_TABLES = ("lints", "badges")

# What a member may set beside `workspace = true` in a dependency. Anything else
# is rejected rather than guessed at, since a key cargo would have merged some
# other way (or refused outright) is a manifest this has never seen.
_DEP_LOCAL_KEYS = ("default-features", "features", "optional", "public")

_MANIFEST = "Cargo.toml"

def _inherits(content):
    """Whether a manifest could inherit anything, decided without parsing.

    A TOML parse of every manifest in a checkout, to find the few that inherit,
    is wasted work. Any inheritance spells `workspace` literally, so a substring
    is a sound over-approximation: it can never miss one, and a false positive
    costs a single parse that then resolves nothing.

    Args:
        content: The contents of a `Cargo.toml`.

    Returns:
        Whether the manifest mentions a workspace at all.
    """
    return _WORKSPACE in content

def _workspace(content, label = _MANIFEST, _fail = fail):
    """The `[workspace]` table of a checkout's root manifest.

    Args:
        content: The contents of the root `Cargo.toml`.
        label: Where the manifest came from, for error messages.
        _fail: Fail function for errors.

    Returns:
        The `[workspace]` table, which holds whatever the members inherit.
    """
    parsed = toml.decode(content)
    workspace = parsed.get(_WORKSPACE)

    if type(workspace) != "dict":
        msg = "{}: no `[{}]` table, so there is nothing for a member of this "
        msg += "checkout to inherit from"
        return _fail(msg.format(label, _WORKSPACE))

    return workspace

def _marker(value):
    """Whether a manifest entry inherits: a table setting `workspace = true`."""
    return type(value) == "dict" and value.get(_WORKSPACE) == True

def _dep_tables(parsed):
    """Every dependency table in a manifest, as `(dotted name, table)`."""
    tables = [(name, parsed[name]) for name in _DEP_TABLES if name in parsed]

    for cfg in sorted(parsed.get("target", {})):
        spec = parsed["target"][cfg]

        tables += [
            ("target.%s.%s" % (cfg, name), spec[name])
            for name in _DEP_TABLES
            if name in spec
        ]

    return tables

def _resolve_package(package, workspace, changed, errors):
    """Substitute the `[package]` fields inherited from `[workspace.package]`."""
    inherited = workspace.get("package", {})

    for field in sorted(package):
        if not _marker(package[field]):
            continue

        extra = [key for key in package[field] if key != _WORKSPACE]

        if extra:
            msg = "`package.{}`: {} set beside `{} = true`"
            errors.append(
                msg.format(field, ", ".join(sorted(extra)), _WORKSPACE),
            )
            continue

        if field not in inherited:
            msg = "`package.{}` inherits, but the root has no `{}.package.{}`"
            errors.append(msg.format(field, _WORKSPACE, field))
            continue

        # Path-valued fields (`readme`, `license-file`, `include`) are copied
        # verbatim rather than rebased on the root, which is what cargo does
        # when it packages. Nothing reads them in a dependency.
        package[field] = inherited[field]
        changed.append("package.%s" % field)

def _resolve_tables(parsed, workspace, changed, errors):
    """Substitute the tables inherited whole, rather than field by field."""
    for table in _INHERITED_TABLES:
        if not _marker(parsed.get(table)):
            continue

        if table not in workspace:
            msg = "`[{}] {} = true`, but the root has no `{}.{}`"
            errors.append(msg.format(table, _WORKSPACE, _WORKSPACE, table))
            continue

        parsed[table] = workspace[table]
        changed.append(table)

def _merge_dep(local, inherited, where, errors):
    """One inherited dependency, merged with the keys the member adds itself."""

    # `[workspace.dependencies] foo = "1.0"` is shorthand for a table holding
    # only that version requirement.
    if type(inherited) == "string":
        merged = {"version": inherited}
    else:
        merged = {
            key: value
            for key, value in inherited.items()
            if key != _WORKSPACE
        }

    added = [key for key in local if key != _WORKSPACE]
    unknown = [key for key in added if key not in _DEP_LOCAL_KEYS]

    if unknown:
        msg = "{}: {} set beside `{} = true`. A member may add only: {}"
        errors.append(msg.format(
            where,
            ", ".join(sorted(unknown)),
            _WORKSPACE,
            ", ".join(_DEP_LOCAL_KEYS),
        ))
        return merged

    for key in added:
        if key == "features":
            # Unioned, not overridden: the member asks for its features ON TOP
            # of whatever the workspace entry already enables.
            features = list(merged.get(key, []))

            merged[key] = features + [
                feature
                for feature in local[key]
                if feature not in features
            ]
        elif key == "default-features" and key in merged:
            # The workspace's answer wins, as it does in cargo, which warns that
            # the member's is ignored rather than honouring it.
            continue
        else:
            merged[key] = local[key]

    return merged

def _resolve_deps(where, deps, inherited, changed, errors):
    """Substitute the dependencies of one table from `[workspace.dependencies]`."""
    for name in sorted(deps):
        if not _marker(deps[name]):
            continue

        if name not in inherited:
            msg = "`{}.{}` inherits, but the root has no `{}.dependencies.{}`"
            errors.append(msg.format(where, name, _WORKSPACE, name))
            continue

        deps[name] = _merge_dep(
            deps[name],
            inherited[name],
            "`%s.%s`" % (where, name),
            errors,
        )
        changed.append("%s.%s" % (where, name))

def _stray(encoded):
    """The table an unresolved inheritance marker was left under, if any.

    The backstop on the whole substitution: whatever this finds is a form of
    inheritance the code above does not know about, and letting it through would
    mean handing cargo a manifest it cannot read. Read off the re-encoded
    manifest rather than the parse, so no shape of input can hide a marker from
    it.
    """
    marker = "%s = true" % _WORKSPACE

    if marker not in encoded:
        return None

    table = "the top-level table"

    for line in encoded.splitlines():
        if line.startswith("["):
            table = line
        elif marker in line:
            return table

    return table

def _resolve(content, workspace, label = _MANIFEST, _fail = fail):
    """Rewrite one member manifest with everything it inherits substituted.

    Args:
        content: The contents of the member's `Cargo.toml`.
        workspace: The root's `[workspace]` table, from `workspace`.
        label: Where the manifest came from, for error messages.
        _fail: Fail function for errors.

    Returns:
        The rewritten manifest, or `None` if it inherits nothing.
    """
    parsed = toml.decode(content)
    changed = []
    errors = []

    if type(parsed.get("package")) == "dict":
        _resolve_package(parsed["package"], workspace, changed, errors)

    _resolve_tables(parsed, workspace, changed, errors)

    inherited = workspace.get("dependencies", {})

    for where, deps in _dep_tables(parsed):
        _resolve_deps(where, deps, inherited, changed, errors)

    if errors:
        return _fail("{}: {}".format(label, ". ".join(errors)))

    if not changed:
        # Nothing inherited, so leave the file exactly as upstream wrote it,
        # comments and formatting and all. Re-encoding would be semantically
        # identical but would churn every manifest that merely says `workspace`,
        # a repo root's own `[workspace]` table included.
        return None

    encoded = toml.encode(parsed)
    stray = _stray(encoded)

    if stray:
        msg = "{}: `{} = true` left unresolved under {}. Inheritance is "
        msg += "substituted for `[package]` fields, for dependencies and for: {}"
        return _fail(msg.format(
            label,
            _WORKSPACE,
            stray,
            ", ".join(_INHERITED_TABLES),
        ))

    return encoded

manifest = struct(
    inherits = _inherits,
    resolve = _resolve,
    workspace = _workspace,
    __test__ = struct(
        _DEP_LOCAL_KEYS = _DEP_LOCAL_KEYS,
        _INHERITED_TABLES = _INHERITED_TABLES,
        _MANIFEST = _MANIFEST,
    ),
)
