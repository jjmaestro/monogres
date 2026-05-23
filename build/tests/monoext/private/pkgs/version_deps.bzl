"""
Unit tests for monoext/private/pkgs/version_deps.bzl.

Tests spec_matches() and get_version_deps(), the logic that maps extension
versions to their dependency package sets via versioned spec maps in repo.json.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@version_utils//version:version.bzl", Version = "version")

# buildifier: disable=bzl-visibility
load(
    "//monoext/private/pkgs:version_deps.bzl",
    "get_version_deps",
    "spec_matches",
    "testing",
)
load("//tests:mock.bzl", "mock")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _wildcard_test_impl(ctx):
    """Wildcard spec matches any version"""
    env = unittest.begin(ctx)

    asserts.true(env, spec_matches("*", "0.3.0"))
    asserts.true(env, spec_matches("*", "13.2.0"))
    asserts.true(env, spec_matches("*", "1.0.0"))

    return unittest.end(env)

wildcard_test = unittest.make(_wildcard_test_impl)

def _semver_exact_test_impl(ctx):
    """Semver exact constraint matches correctly"""
    env = unittest.begin(ctx)

    asserts.true(env, spec_matches(">=13.2.0", "13.2.0"))
    asserts.true(env, spec_matches(">=13.2.0", "13.3.0"))
    asserts.true(env, spec_matches(">=13.2.0", "14.0.0"))
    asserts.false(env, spec_matches(">=13.2.0", "13.1.0"))
    asserts.false(env, spec_matches(">=13.2.0", "12.0.0"))

    return unittest.end(env)

semver_exact_test = unittest.make(_semver_exact_test_impl)

def _semver_patch_test_impl(ctx):
    """Semver three-component comparison works"""
    env = unittest.begin(ctx)

    # these would fail with PGVER because it strips the patch component
    asserts.true(env, spec_matches(">=0.3.0", "0.3.0"))
    asserts.true(env, spec_matches(">=0.3.0", "0.3.1"))
    asserts.true(env, spec_matches(">=0.3.0", "0.4.0"))
    asserts.false(env, spec_matches(">=0.3.0", "0.2.9"))
    asserts.false(env, spec_matches(">=0.3.0", "0.2.0"))

    return unittest.end(env)

semver_patch_test = unittest.make(_semver_patch_test_impl)

def _range_test_impl(ctx):
    """Range constraints match versions within bounds"""
    env = unittest.begin(ctx)

    asserts.true(env, spec_matches(">=1.0.0, <2.0.0", "1.5.0"))
    asserts.false(env, spec_matches(">=1.0.0, <2.0.0", "2.0.0"))
    asserts.false(env, spec_matches(">=1.0.0, <2.0.0", "0.9.0"))

    return unittest.end(env)

range_test = unittest.make(_range_test_impl)

def _pgver_exact_test_impl(ctx):
    """PGVER scheme matches PG-style 2-part versions"""
    env = unittest.begin(ctx)

    pgver = Version.SCHEME.PGVER

    # PG-style versions ("major.minor") parse under PGVER scheme.
    asserts.true(env, spec_matches(">=15.0", "15.0", version_scheme = pgver))
    asserts.true(env, spec_matches(">=15.0", "16.1", version_scheme = pgver))
    asserts.true(env, spec_matches(">=15.0", "17.0", version_scheme = pgver))
    asserts.false(env, spec_matches(">=15.0", "14.5", version_scheme = pgver))

    # Half-open and closed ranges.
    asserts.true(env, spec_matches("<16.0", "15.0", version_scheme = pgver))
    asserts.false(env, spec_matches("<16.0", "16.0", version_scheme = pgver))
    asserts.true(
        env,
        spec_matches(">=16.0, <18.0", "17.4", version_scheme = pgver),
    )
    asserts.false(
        env,
        spec_matches(">=16.0, <18.0", "18.0", version_scheme = pgver),
    )

    return unittest.end(env)

pgver_exact_test = unittest.make(_pgver_exact_test_impl)

def _get_wildcard_test_impl(ctx):
    """Wildcard spec resolves deps for all versions"""
    env = unittest.begin(ctx)

    deps = {"*": ["libssl-dev", "libc6-dev"]}

    result = get_version_deps("13.2.0", deps)
    asserts.equals(env, ["libssl-dev", "libc6-dev"], result)

    result = get_version_deps("0.3.0", deps)
    asserts.equals(env, ["libssl-dev", "libc6-dev"], result)

    return unittest.end(env)

get_wildcard_test = unittest.make(_get_wildcard_test_impl)

def _get_no_match_test_impl(ctx):
    """No match returns an empty list"""
    env = unittest.begin(ctx)

    deps = {">=2.0.0": ["libfoo-dev"]}

    result = get_version_deps("1.0.0", deps)
    asserts.equals(env, [], result)

    return unittest.end(env)

get_no_match_test = unittest.make(_get_no_match_test_impl)

def _get_version_specific_test_impl(ctx):
    """Version-specific specs resolve to different packages"""
    env = unittest.begin(ctx)

    # simulates an extension where v1.x needs pkg-a and v2.x needs pkg-b
    deps = {
        ">=1.0.0, <2.0.0": ["pkg-a"],
        ">=2.0.0": ["pkg-b", "pkg-c"],
    }

    result_v1 = get_version_deps("1.5.0", deps)
    asserts.equals(env, ["pkg-a"], result_v1)

    result_v2 = get_version_deps("2.1.0", deps)
    asserts.equals(env, ["pkg-b", "pkg-c"], result_v2)

    # v0.9 matches neither
    result_v0 = get_version_deps("0.9.0", deps)
    asserts.equals(env, [], result_v0)

    return unittest.end(env)

get_version_specific_test = unittest.make(
    _get_version_specific_test_impl,
)

def _get_empty_spec_map_test_impl(ctx):
    """Empty spec map returns an empty list"""
    env = unittest.begin(ctx)

    result = get_version_deps("1.0.0", {})
    asserts.equals(env, [], result)

    return unittest.end(env)

get_empty_spec_map_test = unittest.make(
    _get_empty_spec_map_test_impl,
)

def _get_multiple_match_fails_test_impl(ctx):
    """Multiple matching specs cause a failure"""
    env = unittest.begin(ctx)

    # both specs match version 1.5.0
    deps = {
        ">=1.0.0": ["pkg-a"],
        ">=1.2.0": ["pkg-b"],
    }

    result = get_version_deps(
        "1.5.0",
        deps,
        _fail = mock.fail,
    )

    # mock.fail returns the error message as a string
    asserts.true(env, type(result) == "string")
    asserts.true(env, "matched multiple dep specs" in result)

    return unittest.end(env)

get_multiple_match_fails_test = unittest.make(
    _get_multiple_match_fails_test_impl,
)

def _get_wildcard_plus_versioned_test_impl(ctx):
    """`"*"` is a base set; a matching version-gated spec unions onto it."""
    env = unittest.begin(ctx)
    pgver = Version.SCHEME.PGVER

    deps = {
        "*": ["base-a", "base-b"],
        "<16.0": ["extra-old"],
    }

    # PG < 16 gets the base plus the version-gated addition.
    asserts.equals(
        env,
        ["base-a", "base-b", "extra-old"],
        get_version_deps("15.0", deps, version_scheme = pgver),
    )

    # PG >= 16 gets the base only.
    asserts.equals(
        env,
        ["base-a", "base-b"],
        get_version_deps("16.0", deps, version_scheme = pgver),
    )

    return unittest.end(env)

get_wildcard_plus_versioned_test = unittest.make(
    _get_wildcard_plus_versioned_test_impl,
)

def _parse_spec_test_impl(ctx):
    """_parse_spec splits version_spec/arch_spec correctly"""
    env = unittest.begin(ctx)

    asserts.equals(env, ("*", "*"), testing._parse_spec("*"))
    asserts.equals(env, ("*", "*"), testing._parse_spec("*/*"))
    asserts.equals(env, ("*", "amd64"), testing._parse_spec("*/amd64"))
    asserts.equals(env, (">=14", "arm64"), testing._parse_spec(">=14/arm64"))
    asserts.equals(env, (">=14", "*"), testing._parse_spec(">=14"))

    return unittest.end(env)

parse_spec_test = unittest.make(_parse_spec_test_impl)

def _arch_matches_test_impl(ctx):
    """_arch_matches handles wildcard, None, and exact match"""
    env = unittest.begin(ctx)

    asserts.true(env, testing._arch_matches("*", "amd64"))
    asserts.true(env, testing._arch_matches("*", None))
    asserts.true(env, testing._arch_matches("amd64", None))
    asserts.true(env, testing._arch_matches("amd64", "amd64"))
    asserts.false(env, testing._arch_matches("amd64", "arm64"))

    return unittest.end(env)

arch_matches_test = unittest.make(_arch_matches_test_impl)

def _spec_matches_arch_test_impl(ctx):
    """spec_matches with arch parameter"""
    env = unittest.begin(ctx)

    asserts.true(env, spec_matches("*", "1.0.0", arch = "amd64"))
    asserts.true(env, spec_matches("*/*", "1.0.0", arch = "amd64"))
    asserts.true(env, spec_matches("*/amd64", "1.0.0", arch = "amd64"))
    asserts.false(env, spec_matches("*/amd64", "1.0.0", arch = "arm64"))
    asserts.true(env, spec_matches(">=14.0.0/arm64", "14.0.0", arch = "arm64"))
    asserts.false(env, spec_matches(">=14.0.0/arm64", "14.0.0", arch = "amd64"))
    asserts.false(env, spec_matches(">=14.0.0/arm64", "13.0.0", arch = "arm64"))

    # no arch = any arch (backward compat)
    asserts.true(env, spec_matches(">=14.0.0", "14.0.0"))
    asserts.true(env, spec_matches(">=14.0.0", "14.0.0", arch = "amd64"))

    return unittest.end(env)

spec_matches_arch_test = unittest.make(_spec_matches_arch_test_impl)

def _get_version_deps_arch_test_impl(ctx):
    """get_version_deps with arch parameter filters correctly"""
    env = unittest.begin(ctx)

    deps = {
        "*/amd64": ["pkg-amd64"],
        "*/arm64": ["pkg-arm64"],
    }

    result = get_version_deps("1.0.0", deps, arch = "amd64")
    asserts.equals(env, ["pkg-amd64"], result)

    result = get_version_deps("1.0.0", deps, arch = "arm64")
    asserts.equals(env, ["pkg-arm64"], result)

    return unittest.end(env)

get_version_deps_arch_test = unittest.make(
    _get_version_deps_arch_test_impl,
)

TEST_SUITE_NAME = "version_deps"

TEST_SUITE_TESTS = dict(
    # spec_matches
    wildcard = wildcard_test,
    semver_exact = semver_exact_test,
    semver_patch = semver_patch_test,
    range = range_test,
    pgver_exact = pgver_exact_test,
    # spec_matches with arch
    parse_spec = parse_spec_test,
    arch_matches = arch_matches_test,
    spec_matches_arch = spec_matches_arch_test,
    # get_version_deps
    get_wildcard = get_wildcard_test,
    get_no_match = get_no_match_test,
    get_version_specific = get_version_specific_test,
    get_empty_spec_map = get_empty_spec_map_test,
    get_multiple_match_fails = get_multiple_match_fails_test,
    get_wildcard_plus_versioned = get_wildcard_plus_versioned_test,
    get_version_deps_arch = get_version_deps_arch_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
