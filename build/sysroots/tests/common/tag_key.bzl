"""
Unit tests for //sysroots/common:tag_key.bzl: tag_key() function.

Bazel's real module-extension tag objects only expose their attrs via `dir(tag)`
+ `getattr`. A plain `struct(...)` has the same surface for those two built-ins,
so mock tags are just structs.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//common:tag_key.bzl", "tag_key")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _mock_tag(**kwargs):
    return struct(**kwargs)

def _same_config_same_key_test_impl(ctx):
    """Two identical tag configs produce the same key."""
    env = unittest.begin(ctx)

    a = _mock_tag(name = "pg", base = "//catalog:repo.json", version = "1")
    b = _mock_tag(name = "pg", base = "//catalog:repo.json", version = "1")

    asserts.equals(env, tag_key(a), tag_key(b))

    return unittest.end(env)

same_config_same_key_test = unittest.make(_same_config_same_key_test_impl)

def _different_attr_different_key_test_impl(ctx):
    """A single differing attr produces a different key."""
    env = unittest.begin(ctx)

    a = _mock_tag(name = "pg", base = "//catalog:repo.json")
    b = _mock_tag(name = "pg", base = "//other:repo.json")

    asserts.true(env, tag_key(a) != tag_key(b))

    return unittest.end(env)

different_attr_different_key_test = unittest.make(
    _different_attr_different_key_test_impl,
)

def _exclude_name_buckets_by_config_test_impl(ctx):
    """`exclude = ["name"]` makes the key depend only on configuration."""
    env = unittest.begin(ctx)

    a = _mock_tag(name = "pg", base = "//catalog:repo.json")
    b = _mock_tag(name = "alt", base = "//catalog:repo.json")

    asserts.true(env, tag_key(a) != tag_key(b))
    asserts.equals(
        env,
        tag_key(a, exclude = ["name"]),
        tag_key(b, exclude = ["name"]),
    )

    return unittest.end(env)

exclude_name_buckets_by_config_test = unittest.make(
    _exclude_name_buckets_by_config_test_impl,
)

def _exclude_arbitrary_attr_test_impl(ctx):
    """`exclude` accepts any attr name, not just `name`."""
    env = unittest.begin(ctx)

    a = _mock_tag(name = "pg", base = "//catalog:repo.json", lock = "//a:l")
    b = _mock_tag(name = "pg", base = "//catalog:repo.json", lock = "//b:l")

    asserts.true(env, tag_key(a) != tag_key(b))
    asserts.equals(
        env,
        tag_key(a, exclude = ["lock"]),
        tag_key(b, exclude = ["lock"]),
    )

    return unittest.end(env)

exclude_arbitrary_attr_test = unittest.make(_exclude_arbitrary_attr_test_impl)

def _hashed_form_is_short_test_impl(ctx):
    """`hashed = True` returns the short `tag-<h1>-<h2>-<n>` form."""
    env = unittest.begin(ctx)

    tag = _mock_tag(name = "pg", base = "//catalog:repo.json", version = "1")

    key = tag_key(tag, hashed = True)
    parts = key.split("-")

    asserts.equals(env, "tag", parts[0])
    asserts.equals(env, 4, len(parts))

    return unittest.end(env)

hashed_form_is_short_test = unittest.make(_hashed_form_is_short_test_impl)

def _hashed_and_readable_diverge_test_impl(ctx):
    """Hashed and readable forms are different string shapes for the same tag."""
    env = unittest.begin(ctx)

    tag = _mock_tag(name = "pg", base = "//catalog:repo.json")

    asserts.true(env, tag_key(tag) != tag_key(tag, hashed = True))

    return unittest.end(env)

hashed_and_readable_diverge_test = unittest.make(
    _hashed_and_readable_diverge_test_impl,
)

TEST_SUITE_NAME = "tag_key"

TEST_SUITE_TESTS = dict(
    different_attr_different_key = different_attr_different_key_test,
    exclude_arbitrary_attr = exclude_arbitrary_attr_test,
    exclude_name_buckets_by_config = exclude_name_buckets_by_config_test,
    hashed_and_readable_diverge = hashed_and_readable_diverge_test,
    hashed_form_is_short = hashed_form_is_short_test,
    same_config_same_key = same_config_same_key_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
