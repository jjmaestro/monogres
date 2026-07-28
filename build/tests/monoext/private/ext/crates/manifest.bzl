"""
Unit tests for monoext/private/ext/crates/manifest.bzl.

Tests `inherits` (the parse-free pre-check that keeps this off the manifests
that need nothing), `workspace` (the root table a member inherits from) and
`resolve` (the substitution itself, in each of the places cargo allows
inheritance, plus the merge rules for the keys a member may add beside it).

The manifests here are shaped after the pgrx fork `vectors` pins, which is the
first checkout in the catalog whose members inherit.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@toml.bzl//:toml.bzl", "toml")

# buildifier: disable=bzl-visibility
load("//monoext/private/ext/crates:manifest.bzl", "manifest")
load("//tests:mock.bzl", Mock = "mock")
load("//tests:suite.bzl", _test_suite = "test_suite")

_ROOT = """\
[workspace]
resolver = "2"
members = ["pgrx", "pgrx-macros"]

[workspace.package]
version = "0.12.5"
edition = "2021"
license = "MIT"

[workspace.dependencies]
pgrx-macros = { path = "./pgrx-macros", version = "=0.12.5" }
eyre = "~0.6.12"
owo-colors = { version = "4.0", features = ["supports-colors"] }
serde = { version = "1.0", features = ["derive"] }
syn = { version = "2", default-features = false, features = ["full"] }

[workspace.lints.clippy]
too-many-arguments = "allow"
"""

_WORKSPACE = manifest.workspace(_ROOT)

def _resolved(content, root = None):
    """`resolve` against `_ROOT`, decoded back into a table to assert on."""
    workspace = manifest.workspace(root) if root else _WORKSPACE

    return toml.decode(manifest.resolve(content, workspace))

def _inherits__detects_a_marker_test_impl(ctx):
    """Any inheritance spells `workspace`, so a substring never misses one."""
    env = unittest.begin(ctx)

    asserts.true(env, manifest.inherits("[dependencies]\neyre.workspace = true\n"))
    asserts.true(env, manifest.inherits('[package]\nworkspace = ".."\n'))

    return unittest.end(env)

inherits__detects_a_marker_test = unittest.make(
    _inherits__detects_a_marker_test_impl,
)

def _inherits__plain_manifest_test_impl(ctx):
    """A self-contained manifest is left untouched, and unparsed."""
    env = unittest.begin(ctx)

    asserts.false(env, manifest.inherits("""\
[package]
name = "tantivy-bitpacker"
version = "0.9.0"

[dependencies]
bitpacking = { version = "0.9.2", default-features = false }
"""))

    return unittest.end(env)

inherits__plain_manifest_test = unittest.make(
    _inherits__plain_manifest_test_impl,
)

def _workspace__missing_table_fails_test_impl(ctx):
    """A member that inherits needs a root that has something to give."""
    env = unittest.begin(ctx)

    res = manifest.workspace(
        '[package]\nname = "x"\n',
        label = "x/Cargo.toml",
        _fail = Mock.fail,
    )

    asserts.true(env, "no `[workspace]` table" in res, res)
    asserts.true(env, "x/Cargo.toml" in res, res)

    return unittest.end(env)

workspace__missing_table_fails_test = unittest.make(
    _workspace__missing_table_fails_test_impl,
)

def _resolve__nothing_inherited_test_impl(ctx):
    """A manifest that says `workspace` but inherits nothing is not rewritten.

    A repo root is the common case: it carries the `[workspace]` table itself,
    and re-encoding it would drop its comments for no gain.
    """
    env = unittest.begin(ctx)

    asserts.equals(env, None, manifest.resolve(_ROOT, _WORKSPACE))

    return unittest.end(env)

resolve__nothing_inherited_test = unittest.make(
    _resolve__nothing_inherited_test_impl,
)

def _resolve__dependency_test_impl(ctx):
    """`eyre.workspace = true` becomes the requirement the root spells."""
    env = unittest.begin(ctx)

    parsed = _resolved("""\
[dependencies]
eyre.workspace = true
convert_case = "0.6.0"
""")

    asserts.equals(env, {"version": "~0.6.12"}, parsed["dependencies"]["eyre"])

    # Everything the member declares itself survives the round trip.
    asserts.equals(env, "0.6.0", parsed["dependencies"]["convert_case"])

    return unittest.end(env)

resolve__dependency_test = unittest.make(_resolve__dependency_test_impl)

def _resolve__dependency_table_test_impl(ctx):
    """A root entry that is a table is substituted whole, `path` included.

    The `path` is kept because cargo ignores it for a package it resolves
    through a replaced source, and dropping it would be a second change to
    justify.
    """
    env = unittest.begin(ctx)

    parsed = _resolved("[dependencies]\npgrx-macros.workspace = true\n")

    asserts.equals(env, {
        "path": "./pgrx-macros",
        "version": "=0.12.5",
    }, parsed["dependencies"]["pgrx-macros"])

    return unittest.end(env)

resolve__dependency_table_test = unittest.make(
    _resolve__dependency_table_test_impl,
)

def _resolve__features_unioned_test_impl(ctx):
    """A member's features are added to the root's, not swapped for them."""
    env = unittest.begin(ctx)

    parsed = _resolved("""\
[dependencies]
serde = { workspace = true, features = ["rc", "derive"] }
""")

    # "derive" comes from the root and is asked for again here: unioning has to
    # dedupe, since cargo would take a repeat as one feature either way.
    asserts.equals(env, ["derive", "rc"], parsed["dependencies"]["serde"]["features"])
    asserts.equals(env, "1.0", parsed["dependencies"]["serde"]["version"])

    return unittest.end(env)

resolve__features_unioned_test = unittest.make(
    _resolve__features_unioned_test_impl,
)

def _resolve__optional_test_impl(ctx):
    """`optional` is the member's to set, and only the member's."""
    env = unittest.begin(ctx)

    parsed = _resolved("""\
[dependencies]
owo-colors = { optional = true, workspace = true }
""")

    asserts.equals(env, {
        "features": ["supports-colors"],
        "optional": True,
        "version": "4.0",
    }, parsed["dependencies"]["owo-colors"])

    return unittest.end(env)

resolve__optional_test = unittest.make(_resolve__optional_test_impl)

def _resolve__default_features_test_impl(ctx):
    """The root's `default-features` wins, as it does in cargo."""
    env = unittest.begin(ctx)

    parsed = _resolved("""\
[dependencies]
syn = { workspace = true, default-features = true }
eyre = { workspace = true, default-features = false }
""")

    # The root turned them off for `syn`, so the member asking for them back is
    # ignored; the root says nothing about `eyre`, so the member decides.
    asserts.equals(env, False, parsed["dependencies"]["syn"]["default-features"])
    asserts.equals(env, False, parsed["dependencies"]["eyre"]["default-features"])

    return unittest.end(env)

resolve__default_features_test = unittest.make(
    _resolve__default_features_test_impl,
)

def _resolve__every_dependency_table_test_impl(ctx):
    """Inheritance works the same in dev, build and per-target tables."""
    env = unittest.begin(ctx)

    parsed = _resolved("""\
[dev-dependencies]
eyre.workspace = true

[build-dependencies]
serde.workspace = true

[target.'cfg(target_os = "linux")'.dependencies]
owo-colors.workspace = true
""")

    asserts.equals(env, "~0.6.12", parsed["dev-dependencies"]["eyre"]["version"])
    asserts.equals(env, "1.0", parsed["build-dependencies"]["serde"]["version"])

    target = parsed["target"]['cfg(target_os = "linux")']
    asserts.equals(env, "4.0", target["dependencies"]["owo-colors"]["version"])

    return unittest.end(env)

resolve__every_dependency_table_test = unittest.make(
    _resolve__every_dependency_table_test_impl,
)

def _resolve__package_fields_test_impl(ctx):
    """`[package]` fields come from `[workspace.package]`, one by one."""
    env = unittest.begin(ctx)

    parsed = _resolved("""\
[package]
name = "pgrx-macros"
version.workspace = true
edition.workspace = true
license = "Apache-2.0"
""")

    asserts.equals(env, "0.12.5", parsed["package"]["version"])
    asserts.equals(env, "2021", parsed["package"]["edition"])

    # A field the member sets itself is not the root's to override.
    asserts.equals(env, "Apache-2.0", parsed["package"]["license"])

    return unittest.end(env)

resolve__package_fields_test = unittest.make(
    _resolve__package_fields_test_impl,
)

def _resolve__lints_table_test_impl(ctx):
    """`[lints]` is inherited whole rather than field by field."""
    env = unittest.begin(ctx)

    parsed = _resolved("[lints]\nworkspace = true\n")

    asserts.equals(
        env,
        {"clippy": {"too-many-arguments": "allow"}},
        parsed["lints"],
    )

    return unittest.end(env)

resolve__lints_table_test = unittest.make(_resolve__lints_table_test_impl)

def _resolve__keeps_the_rest_test_impl(ctx):
    """Re-encoding a manifest changes what it says about nothing else."""
    env = unittest.begin(ctx)

    parsed = _resolved("""\
[package]
name = "pgrx-sql-entity-graph"
version = "0.12.5"
include = ["src/**/*", "README.md"]

[features]
syntax-highlighting = ["dep:syntect", "dep:owo-colors"]
no-schema-generation = []

[dependencies]
eyre.workspace = true

[[bench]]
name = "bench_merge"
harness = false

[lints.clippy]
assigning-clones = "allow"
""")

    asserts.equals(env, ["src/**/*", "README.md"], parsed["package"]["include"])
    asserts.equals(env, [], parsed["features"]["no-schema-generation"])
    asserts.equals(env, [{
        "harness": False,
        "name": "bench_merge",
    }], parsed["bench"])
    asserts.equals(env, "allow", parsed["lints"]["clippy"]["assigning-clones"])

    return unittest.end(env)

resolve__keeps_the_rest_test = unittest.make(_resolve__keeps_the_rest_test_impl)

def _resolve__unknown_dependency_fails_test_impl(ctx):
    """A member cannot inherit a dependency the root never declared."""
    env = unittest.begin(ctx)

    res = manifest.resolve(
        "[dependencies]\nrayon.workspace = true\n",
        _WORKSPACE,
        label = "pgrx/Cargo.toml",
        _fail = Mock.fail,
    )

    asserts.true(env, "`dependencies.rayon` inherits" in res, res)
    asserts.true(env, "workspace.dependencies.rayon" in res, res)
    asserts.true(env, "pgrx/Cargo.toml" in res, res)

    return unittest.end(env)

resolve__unknown_dependency_fails_test = unittest.make(
    _resolve__unknown_dependency_fails_test_impl,
)

def _resolve__unknown_local_key_fails_test_impl(ctx):
    """A key cargo merges some other way is refused, not guessed at."""
    env = unittest.begin(ctx)

    res = manifest.resolve(
        '[dependencies]\neyre = { workspace = true, version = "1" }\n',
        _WORKSPACE,
        _fail = Mock.fail,
    )

    asserts.true(env, "version set beside `workspace = true`" in res, res)

    return unittest.end(env)

resolve__unknown_local_key_fails_test = unittest.make(
    _resolve__unknown_local_key_fails_test_impl,
)

def _resolve__unknown_package_field_fails_test_impl(ctx):
    """A `[package]` field the root does not carry cannot be substituted."""
    env = unittest.begin(ctx)

    res = manifest.resolve(
        "[package]\nrust-version.workspace = true\n",
        _WORKSPACE,
        _fail = Mock.fail,
    )

    asserts.true(env, "`package.rust-version` inherits" in res, res)
    asserts.true(env, "workspace.package.rust-version" in res, res)

    return unittest.end(env)

resolve__unknown_package_field_fails_test = unittest.make(
    _resolve__unknown_package_field_fails_test_impl,
)

def _resolve__stray_marker_fails_test_impl(ctx):
    """A form of inheritance this does not know about is not let through.

    `[badges]` is handled, `[example]` is not: an unresolved marker reaches
    cargo as a manifest it cannot read, so it has to be caught here instead.
    """
    env = unittest.begin(ctx)

    res = manifest.resolve(
        "[dependencies]\neyre.workspace = true\n\n[example]\nworkspace = true\n",
        _WORKSPACE,
        _fail = Mock.fail,
    )

    asserts.true(env, "left unresolved under [example]" in res, res)

    return unittest.end(env)

resolve__stray_marker_fails_test = unittest.make(
    _resolve__stray_marker_fails_test_impl,
)

TEST_SUITE_NAME = "monoext/private/ext/crates/manifest"

TEST_SUITE_TESTS = {
    "inherits/detects_a_marker": inherits__detects_a_marker_test,
    "inherits/plain_manifest": inherits__plain_manifest_test,
    "resolve/default_features": resolve__default_features_test,
    "resolve/dependency": resolve__dependency_test,
    "resolve/dependency_table": resolve__dependency_table_test,
    "resolve/every_dependency_table": resolve__every_dependency_table_test,
    "resolve/features_unioned": resolve__features_unioned_test,
    "resolve/keeps_the_rest": resolve__keeps_the_rest_test,
    "resolve/lints_table": resolve__lints_table_test,
    "resolve/nothing_inherited": resolve__nothing_inherited_test,
    "resolve/optional": resolve__optional_test,
    "resolve/package_fields": resolve__package_fields_test,
    "resolve/stray_marker_fails": resolve__stray_marker_fails_test,
    "resolve/unknown_dependency_fails": resolve__unknown_dependency_fails_test,
    "resolve/unknown_local_key_fails": resolve__unknown_local_key_fails_test,
    "resolve/unknown_package_field_fails": resolve__unknown_package_field_fails_test,
}

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
