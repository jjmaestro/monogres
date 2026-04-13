"""
Unit tests for monoext/private/pkgs.bzl pure helpers.

Exercises `_group_labels(hub_name, group)`: maps a resolved `AptGroup` to a list
of `@{hub}//deb/{r}:{r}` labels.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private:pkgs.bzl", _Pkgs = "testing")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _group_labels_builds_per_package_label_test_impl(ctx):
    """Each resolved name becomes `@{hub}//deb/{r}:{r}`."""
    env = unittest.begin(ctx)

    group = struct(
        resolved_names = ["libssl-dev", "libc6-dev"],
    )

    labels = _Pkgs._group_labels("pg_pkgs", group)

    asserts.equals(
        env,
        [
            "@pg_pkgs//deb/libssl-dev:libssl-dev",
            "@pg_pkgs//deb/libc6-dev:libc6-dev",
        ],
        labels,
    )

    return unittest.end(env)

group_labels_builds_per_package_label_test = unittest.make(
    _group_labels_builds_per_package_label_test_impl,
)

def _group_labels_empty_group_test_impl(ctx):
    """Empty `resolved_names` → empty label list."""
    env = unittest.begin(ctx)

    labels = _Pkgs._group_labels("pg_pkgs", struct(resolved_names = []))
    asserts.equals(env, [], labels)

    return unittest.end(env)

group_labels_empty_group_test = unittest.make(
    _group_labels_empty_group_test_impl,
)

def _group_labels_hub_name_parametric_test_impl(ctx):
    """The hub name parameter is interpolated in every label."""
    env = unittest.begin(ctx)

    labels = _Pkgs._group_labels(
        "foo_pkgs",
        struct(resolved_names = ["libssl-dev"]),
    )
    asserts.equals(
        env,
        ["@foo_pkgs//deb/libssl-dev:libssl-dev"],
        labels,
    )

    return unittest.end(env)

group_labels_hub_name_parametric_test = unittest.make(
    _group_labels_hub_name_parametric_test_impl,
)

TEST_SUITE_NAME = "pkgs_top"

TEST_SUITE_TESTS = dict(
    group_labels_builds_per_package_label = group_labels_builds_per_package_label_test,
    group_labels_empty_group = group_labels_empty_group_test,
    group_labels_hub_name_parametric = group_labels_hub_name_parametric_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
