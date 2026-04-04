"""
Unit tests for `//sysroots/apt/private:manifest.bzl`.

Covers `parse_manifest` (version check, missing-fields tolerance) and
`resolve_attrs` (tag-attr-wins merge, defaults, required-field failures).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//apt/private:manifest.bzl", _manifest = "manifest")
load("//common:archs.bzl", _DEFAULT_ARCHS = "ARCHS")
load("//tests:suite.bzl", _test_suite = "test_suite")

_VALID_MANIFEST = {
    "archs": ["amd64", "arm64"],
    "distro": "debian",
    "distro_version": "12",
    "packages": ["libc6-dev", "libgcc-12-dev"],
    "snapshot": "20250113T000000Z",
    "version": 1,
}

def _parse_happy_test_impl(ctx):
    """A well-formed manifest parses to a struct with all fields."""
    env = unittest.begin(ctx)
    m = _manifest.parse(json.encode(_VALID_MANIFEST))
    asserts.equals(env, "debian", m.distro)
    asserts.equals(env, "12", m.version)
    asserts.equals(env, ["amd64", "arm64"], m.archs)
    asserts.equals(env, ["libc6-dev", "libgcc-12-dev"], m.packages)
    asserts.equals(env, "20250113T000000Z", m.snapshot)
    return unittest.end(env)

parse_happy_test = unittest.make(_parse_happy_test_impl)

def _parse_missing_fields_test_impl(ctx):
    """Missing fields are tolerated by parse; required check happens after merge."""
    env = unittest.begin(ctx)
    m = _manifest.parse(json.encode({"version": 1}))
    asserts.equals(env, None, m.distro)
    asserts.equals(env, None, m.version)
    asserts.equals(env, None, m.archs)
    asserts.equals(env, None, m.packages)
    asserts.equals(env, None, m.snapshot)
    return unittest.end(env)

parse_missing_fields_test = unittest.make(_parse_missing_fields_test_impl)

def _resolve_tag_only_test_impl(ctx):
    """All attrs from tag (no manifest)."""
    env = unittest.begin(ctx)
    m = _manifest.resolve_attrs(
        name = "test",
        distro = "debian",
        version = "12",
        archs = ["amd64"],
        packages = ["libc6-dev"],
        snapshot = "20250113T000000Z",
        manifest = None,
    )
    asserts.equals(env, "debian", m.distro)
    asserts.equals(env, "12", m.version)
    asserts.equals(env, ["amd64"], m.archs)
    asserts.equals(env, ["libc6-dev"], m.packages)
    asserts.equals(env, "20250113T000000Z", m.snapshot)
    return unittest.end(env)

resolve_tag_only_test = unittest.make(_resolve_tag_only_test_impl)

def _resolve_manifest_only_test_impl(ctx):
    """All attrs from manifest (tag attrs empty)."""
    env = unittest.begin(ctx)
    parsed = _manifest.parse(json.encode(_VALID_MANIFEST))
    m = _manifest.resolve_attrs(
        name = "test",
        distro = "",
        version = "",
        archs = [],
        packages = [],
        snapshot = "",
        manifest = parsed,
    )
    asserts.equals(env, "debian", m.distro)
    asserts.equals(env, "12", m.version)
    asserts.equals(env, ["amd64", "arm64"], m.archs)
    asserts.equals(env, ["libc6-dev", "libgcc-12-dev"], m.packages)
    asserts.equals(env, "20250113T000000Z", m.snapshot)
    return unittest.end(env)

resolve_manifest_only_test = unittest.make(_resolve_manifest_only_test_impl)

def _resolve_tag_overrides_manifest_test_impl(ctx):
    """Tag attrs win over manifest fields when both are set."""
    env = unittest.begin(ctx)
    parsed = _manifest.parse(json.encode(_VALID_MANIFEST))
    m = _manifest.resolve_attrs(
        name = "test",
        distro = "debian",  # explicit, same as manifest
        version = "11",  # explicit, OVERRIDES manifest's "12"
        archs = ["amd64"],  # explicit, OVERRIDES manifest's both
        packages = ["only-libc6"],  # explicit, OVERRIDES manifest's two
        snapshot = "20260101T000000Z",  # explicit, OVERRIDES manifest
        manifest = parsed,
    )
    asserts.equals(env, "11", m.version)
    asserts.equals(env, ["amd64"], m.archs)
    asserts.equals(env, ["only-libc6"], m.packages)
    asserts.equals(env, "20260101T000000Z", m.snapshot)
    return unittest.end(env)

resolve_tag_overrides_manifest_test = unittest.make(
    _resolve_tag_overrides_manifest_test_impl,
)

def _resolve_archs_defaults_test_impl(ctx):
    """archs defaults to //common:archs.bzl::ARCHS when both empty."""
    env = unittest.begin(ctx)
    m = _manifest.resolve_attrs(
        name = "test",
        distro = "debian",
        version = "12",
        archs = [],
        packages = ["libc6-dev"],
        snapshot = "20250113T000000Z",
        manifest = None,
    )
    asserts.equals(env, sorted(_DEFAULT_ARCHS), m.archs)
    return unittest.end(env)

resolve_archs_defaults_test = unittest.make(_resolve_archs_defaults_test_impl)

def _resolve_packages_dedup_sort_test_impl(ctx):
    """Packages are deduplicated and sorted."""
    env = unittest.begin(ctx)
    m = _manifest.resolve_attrs(
        name = "test",
        distro = "debian",
        version = "12",
        archs = ["amd64"],
        packages = ["libc6-dev", "libgcc", "libc6-dev"],
        snapshot = "20250113T000000Z",
        manifest = None,
    )
    asserts.equals(env, ["libc6-dev", "libgcc"], m.packages)
    return unittest.end(env)

resolve_packages_dedup_sort_test = unittest.make(
    _resolve_packages_dedup_sort_test_impl,
)

def _manifest_version_constant_test_impl(ctx):
    """The exported `MANIFEST_VERSION` constant is 1."""
    env = unittest.begin(ctx)
    asserts.equals(env, 1, _manifest.MANIFEST_VERSION)
    return unittest.end(env)

manifest_version_constant_test = unittest.make(
    _manifest_version_constant_test_impl,
)

TEST_SUITE_NAME = "manifest"

TEST_SUITE_TESTS = dict(
    manifest_version_constant = manifest_version_constant_test,
    parse_happy = parse_happy_test,
    parse_missing_fields = parse_missing_fields_test,
    resolve_archs_defaults = resolve_archs_defaults_test,
    resolve_manifest_only = resolve_manifest_only_test,
    resolve_packages_dedup_sort = resolve_packages_dedup_sort_test,
    resolve_tag_only = resolve_tag_only_test,
    resolve_tag_overrides_manifest = resolve_tag_overrides_manifest_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
