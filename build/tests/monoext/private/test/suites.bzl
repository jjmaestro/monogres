"""
Unit tests for build/monoext/private/test/suites.bzl.

Focuses on `_effective_override` (per-kind override resolution), the
`_bazel_size` sizing band and `_repeated_flag` (list-valued harness flags), the
pure helpers most likely to regress silently.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/test:suites.bzl", _suites = "testing")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _effective_override_test_impl(ctx):
    env = unittest.begin(ctx)
    eo = _suites._effective_override

    # flat-only flags apply to every kind.
    flat = {"encoding": "UTF8"}
    asserts.equals(env, {"encoding": "UTF8"}, eo(flat, "regress"))
    asserts.equals(env, {"encoding": "UTF8"}, eo(flat, "isolation"))

    # the postgres_fdw case: load_extension scoped under `isolation` only.
    fdw = {"isolation": {"load_extension": ["postgres_fdw"]}}
    asserts.equals(env, {}, eo(fdw, "regress"))
    asserts.equals(
        env,
        {"load_extension": ["postgres_fdw"]},
        eo(fdw, "isolation"),
    )

    # flat + per-kind overlay: flat seen by both, kind sub-dict adds for its
    # kind.
    mixed = {"isolation": {"load_extension": ["e"]}, "temp_config": "x.conf"}
    asserts.equals(env, {"temp_config": "x.conf"}, eo(mixed, "regress"))
    asserts.equals(
        env,
        {"load_extension": ["e"], "temp_config": "x.conf"},
        eo(mixed, "isolation"),
    )

    # an empty override stays empty for any kind.
    asserts.equals(env, {}, eo({}, "regress"))

    # the schedule-filter + cosmetic-golden flat flags (and the
    # documentation-only note/known_failure) pass through for every kind.
    newkeys = {
        "exclude_tests": ["timeouts"],
        "golden_cosmetic": True,
        "known_failure": "expected to fail",
        "note": "why",
    }
    asserts.equals(env, newkeys, eo(newkeys, "regress"))
    asserts.equals(env, newkeys, eo(newkeys, "isolation"))

    # the openHalo postgres_fdw shape: golden_cosmetic scoped to `regress`,
    # load_extension scoped to `isolation` -- each kind sees only its own.
    pf = {
        "isolation": {"load_extension": ["postgres_fdw"]},
        "regress": {"golden_cosmetic": True},
    }
    asserts.equals(env, {"golden_cosmetic": True}, eo(pf, "regress"))
    asserts.equals(
        env,
        {"load_extension": ["postgres_fdw"]},
        eo(pf, "isolation"),
    )

    return unittest.end(env)

effective_override_test = unittest.make(_effective_override_test_impl)

def _bazel_size_test_impl(ctx):
    env = unittest.begin(ctx)
    size = _suites._bazel_size

    # single-test group -> medium (the floor: every suite starts a server, so
    # none is `small`/60s, which flakes to TIMEOUT under full-lane CPU
    # contention).
    asserts.equals(env, "medium", size(struct(
        slug = "cube",
        max_timeout = 0,
        test_count = 1,
    )))

    # multi-test group -> medium.
    asserts.equals(env, "medium", size(struct(
        slug = "regress",
        max_timeout = 0,
        test_count = 217,
    )))

    # isolation (a _BIG_SUITES member) -> large regardless of count.
    asserts.equals(env, "large", size(struct(
        slug = "isolation",
        max_timeout = 0,
        test_count = 1,
    )))

    # the heavy multi-cluster / timing-sensitive TAP suites (pg_basebackup,
    # pg_ctl) are _BIG_SUITES members too -> large, so the full lane reserves
    # more CPU for them and does not starve them into a TIMEOUT or restart race.
    for slug in ("pg_basebackup", "pg_ctl"):
        asserts.equals(env, "large", size(struct(
            slug = slug,
            max_timeout = 0,
            test_count = 1,
        )))

    return unittest.end(env)

bazel_size_test = unittest.make(_bazel_size_test_impl)

def _bazel_tags_test_impl(ctx):
    env = unittest.begin(ctx)
    tags = _suites._bazel_tags

    def info(kind, slug, uses_20conn = False):
        return struct(kind = kind, slug = slug, uses_20conn = uses_20conn)

    # a heavy multi-cluster TAP suite (a _BIG_SUITES slug) reserves CPU so the
    # full lane does not co-schedule a cluster-start storm that flakes a `pg_ctl
    # start` / recovery startup.
    asserts.equals(
        env,
        ["regress", "tap", "cpu:4"],
        tags(info("tap", "recovery")),
    )
    asserts.equals(
        env,
        ["regress", "tap", "cpu:4"],
        tags(info("tap", "pg_ctl")),
    )

    # a light TAP suite (not in _BIG_SUITES) keeps the default CPU estimate.
    asserts.equals(env, ["regress", "tap"], tags(info("tap", "pg_config")))

    # the CPU reservation is TAP-only: a _BIG_SUITES regress/isolation slug does
    # not get it (the `cpu:20` 20-conn fan-out is the regress lever).
    asserts.equals(
        env,
        ["regress", "isolation"],
        tags(info("isolation", "isolation")),
    )
    asserts.equals(env, ["regress"], tags(info("regress", "regress")))

    return unittest.end(env)

bazel_tags_test = unittest.make(_bazel_tags_test_impl)

def _repeated_flag_test_impl(ctx):
    """A list-valued harness flag repeats, and never space-joins its values.

    A rule's `args` are Bourne-tokenized before the harness sees them, so one
    flag holding "a b c" arrives as four argv entries and everything after `a`
    is silently dropped. Space-joining is the failure this asserts against.
    """
    env = unittest.begin(ctx)
    rf = _suites._repeated_flag

    asserts.equals(
        env,
        ["--tests", "setup", "--tests", "aggregate", "--tests", "aliases"],
        rf("--tests", ["setup", "aggregate", "aliases"]),
    )

    # Order is the caller's: pg_regress runs a `--tests` list in order, and a
    # suite's first test is often the one that sets the rest up.
    asserts.equals(
        env,
        ["--tests", "b", "--tests", "a"],
        rf("--tests", ["b", "a"]),
    )

    asserts.equals(env, ["--exclude-tests", "timeouts"], rf(
        "--exclude-tests",
        ["timeouts"],
    ))
    asserts.equals(env, [], rf("--tests", []))

    return unittest.end(env)

repeated_flag_test = unittest.make(_repeated_flag_test_impl)

TEST_SUITE_NAME = "suites"

TEST_SUITE_TESTS = dict(
    bazel_size = bazel_size_test,
    bazel_tags = bazel_tags_test,
    effective_override = effective_override_test,
    repeated_flag = repeated_flag_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
