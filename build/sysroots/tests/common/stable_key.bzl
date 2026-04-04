"""
Unit tests for //sysroots/common:stable_key.bzl: stable_key() function.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//common:stable_key.bzl", "stable_key")
load("//tests:suite.bzl", _test_suite = "test_suite")

# ---------------------------------------------------------------------------
# hashed = True (default)
# ---------------------------------------------------------------------------

def _deterministic_test_impl(ctx):
    """Same input always produces the same output"""
    env = unittest.begin(ctx)

    deps = ["@pkgs//deb/pkg-a:pkg-a", "@pkgs//deb/pkg-b:pkg-b"]
    key1 = stable_key(deps, prefix = "sysroot")
    key2 = stable_key(deps, prefix = "sysroot")

    asserts.equals(env, key1, key2)

    return unittest.end(env)

deterministic_test = unittest.make(_deterministic_test_impl)

def _format_test_impl(ctx):
    """Output matches "{prefix}-{hash}-{hash}-{count}" format"""
    env = unittest.begin(ctx)

    key = stable_key(["a", "b", "c"], prefix = "sysroot")
    parts = key.split("-")

    asserts.equals(env, 4, len(parts))
    asserts.equals(env, "sysroot", parts[0])
    asserts.equals(env, "3", parts[3])  # count

    return unittest.end(env)

format_test = unittest.make(_format_test_impl)

def _count_test_impl(ctx):
    """Count reflects deduplicated set size"""
    env = unittest.begin(ctx)

    key1 = stable_key(["a"], prefix = "sysroot")
    key3 = stable_key(["a", "b", "c"], prefix = "sysroot")

    asserts.true(env, key1.endswith("-1"))
    asserts.true(env, key3.endswith("-3"))

    return unittest.end(env)

count_test = unittest.make(_count_test_impl)

def _order_independence_test_impl(ctx):
    """Different input order produces the same key"""
    env = unittest.begin(ctx)

    key_abc = stable_key(["a", "b", "c"], prefix = "sysroot")
    key_cba = stable_key(["c", "b", "a"], prefix = "sysroot")
    key_bac = stable_key(["b", "a", "c"], prefix = "sysroot")

    asserts.equals(env, key_abc, key_cba)
    asserts.equals(env, key_abc, key_bac)

    return unittest.end(env)

order_independence_test = unittest.make(_order_independence_test_impl)

def _dedup_test_impl(ctx):
    """Repeated items produce the same key as the unique set"""
    env = unittest.begin(ctx)

    key_unique = stable_key(["a", "b"], prefix = "sysroot")
    key_dupes = stable_key(["a", "b", "a", "b", "a"], prefix = "sysroot")

    asserts.equals(env, key_unique, key_dupes)

    return unittest.end(env)

dedup_test = unittest.make(_dedup_test_impl)

def _different_sets_test_impl(ctx):
    """Different sets produce different keys"""
    env = unittest.begin(ctx)

    key_ab = stable_key(["a", "b"], prefix = "sysroot")
    key_ac = stable_key(["a", "c"], prefix = "sysroot")
    key_abc = stable_key(["a", "b", "c"], prefix = "sysroot")

    asserts.true(env, key_ab != key_ac)
    asserts.true(env, key_ab != key_abc)
    asserts.true(env, key_ac != key_abc)

    return unittest.end(env)

different_sets_test = unittest.make(_different_sets_test_impl)

def _subset_superset_test_impl(ctx):
    """Subset and superset produce different keys"""
    env = unittest.begin(ctx)

    key_sub = stable_key(["a", "b"], prefix = "sysroot")
    key_super = stable_key(["a", "b", "c"], prefix = "sysroot")

    asserts.true(env, key_sub != key_super)

    return unittest.end(env)

subset_superset_test = unittest.make(_subset_superset_test_impl)

def _empty_test_impl(ctx):
    """Empty input produces a key ending in -0"""
    env = unittest.begin(ctx)

    key = stable_key([], prefix = "sysroot")

    asserts.true(env, key.endswith("-0"))

    return unittest.end(env)

empty_test = unittest.make(_empty_test_impl)

def _single_element_test_impl(ctx):
    """Single element produces a valid key ending in -1"""
    env = unittest.begin(ctx)

    key = stable_key(["@pkgs//deb/pkg-a:pkg-a"], prefix = "sysroot")

    asserts.true(env, key.startswith("sysroot-"))
    asserts.true(env, key.endswith("-1"))

    return unittest.end(env)

single_element_test = unittest.make(_single_element_test_impl)

def _arch_labels_test_impl(ctx):
    """Cross-arch vs arch-specific labels produce different keys"""
    env = unittest.begin(ctx)

    cross_arch = stable_key([
        "@pkgs//deb/pkg-a:pkg-a",
        "@pkgs//deb/pkg-b:pkg-b",
    ], prefix = "sysroot")
    amd64 = stable_key([
        "@pkgs//deb/pkg-a/amd64:amd64",
        "@pkgs//deb/pkg-b/amd64:amd64",
    ], prefix = "sysroot")
    arm64 = stable_key([
        "@pkgs//deb/pkg-a/arm64:arm64",
        "@pkgs//deb/pkg-b/arm64:arm64",
    ], prefix = "sysroot")

    # All three should produce different keys
    asserts.true(env, cross_arch != amd64)
    asserts.true(env, cross_arch != arm64)
    asserts.true(env, amd64 != arm64)

    return unittest.end(env)

arch_labels_test = unittest.make(_arch_labels_test_impl)

def _version_labels_test_impl(ctx):
    """Version-specific labels produce a different key"""
    env = unittest.begin(ctx)

    by_name = stable_key([
        "@pkgs//deb/pkg-a:pkg-a",
    ], prefix = "sysroot")
    by_version = stable_key([
        "@pkgs//deb/pkg-a:3.0.15-1~deb12u1",
    ], prefix = "sysroot")

    asserts.true(env, by_name != by_version)

    return unittest.end(env)

version_labels_test = unittest.make(_version_labels_test_impl)

def _hub_label_composition_test_impl(ctx):
    """Hub label construction + stable_key pattern used by create_pkgs"""
    env = unittest.begin(ctx)

    hub_name = "pkgs"
    resolved_names = ["pkg-a", "pkg-b"]

    labels = [
        "@%s//deb/%s:%s" % (hub_name, r, r)
        for r in resolved_names
    ]

    asserts.equals(env, [
        "@pkgs//deb/pkg-a:pkg-a",
        "@pkgs//deb/pkg-b:pkg-b",
    ], labels)

    sk = stable_key(labels, prefix = "sysroot")
    sysroot_label = "@%s//deb/sysroots:%s" % (hub_name, sk)

    asserts.true(env, sysroot_label.startswith("@pkgs//deb/sysroots:sysroot-"))

    return unittest.end(env)

hub_label_composition_test = unittest.make(
    _hub_label_composition_test_impl,
)

def _hub_label_different_groups_different_sysroots_test_impl(ctx):
    """Different resolved_names produce different sysroot labels"""
    env = unittest.begin(ctx)

    hub_name = "pkgs"

    labels_a = ["@%s//deb/pkg-a:pkg-a" % hub_name]
    labels_b = [
        "@%s//deb/pkg-a:pkg-a" % hub_name,
        "@%s//deb/pkg-b:pkg-b" % hub_name,
    ]

    sk_a = stable_key(labels_a, prefix = "sysroot")
    sk_b = stable_key(labels_b, prefix = "sysroot")

    asserts.true(env, sk_a != sk_b)

    return unittest.end(env)

hub_label_different_groups_different_sysroots_test = unittest.make(
    _hub_label_different_groups_different_sysroots_test_impl,
)

# ---------------------------------------------------------------------------
# hashed = False
# ---------------------------------------------------------------------------

def _unhashed_format_test_impl(ctx):
    """hashed=False produces "{prefix}-{items_joined}" """
    env = unittest.begin(ctx)

    key = stable_key(["b", "a", "c"], prefix = "tag", hashed = False)

    # Items are sorted and joined with "|".
    asserts.equals(env, "tag-a|b|c", key)

    return unittest.end(env)

unhashed_format_test = unittest.make(_unhashed_format_test_impl)

def _unhashed_dedup_test_impl(ctx):
    """hashed=False still dedups"""
    env = unittest.begin(ctx)

    key_unique = stable_key(["a", "b"], prefix = "tag", hashed = False)
    key_dupes = stable_key(["a", "b", "a"], prefix = "tag", hashed = False)

    asserts.equals(env, key_unique, key_dupes)

    return unittest.end(env)

unhashed_dedup_test = unittest.make(_unhashed_dedup_test_impl)

def _unhashed_order_independence_test_impl(ctx):
    """hashed=False is order-independent"""
    env = unittest.begin(ctx)

    key_abc = stable_key(["a", "b", "c"], prefix = "tag", hashed = False)
    key_cba = stable_key(["c", "b", "a"], prefix = "tag", hashed = False)

    asserts.equals(env, key_abc, key_cba)

    return unittest.end(env)

unhashed_order_independence_test = unittest.make(
    _unhashed_order_independence_test_impl,
)

def _unhashed_empty_test_impl(ctx):
    """hashed=False on empty input returns just the prefix"""
    env = unittest.begin(ctx)

    key = stable_key([], prefix = "tag", hashed = False)

    asserts.equals(env, "tag-", key)

    return unittest.end(env)

unhashed_empty_test = unittest.make(_unhashed_empty_test_impl)

TEST_SUITE_NAME = "stable_key"

TEST_SUITE_TESTS = dict(
    # core properties (hashed = True)
    deterministic = deterministic_test,
    format = format_test,
    count = count_test,
    order_independence = order_independence_test,
    dedup = dedup_test,
    # differentiation
    different_sets = different_sets_test,
    subset_superset = subset_superset_test,
    # edge cases
    empty = empty_test,
    single_element = single_element_test,
    # realistic label scenarios
    arch_labels = arch_labels_test,
    version_labels = version_labels_test,
    # composition (hub label + sysroot key pattern)
    hub_label_composition = hub_label_composition_test,
    hub_label_different_groups = hub_label_different_groups_different_sysroots_test,
    # hashed = False
    unhashed_format = unhashed_format_test,
    unhashed_dedup = unhashed_dedup_test,
    unhashed_order_independence = unhashed_order_independence_test,
    unhashed_empty = unhashed_empty_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
