"""
Unit tests for build/monoext/private/test/schema.bzl.

Locks the two introspect decoders into the same `{slug: [SuiteInfo]}` shape:

- `suites_from_metadata_test` (make path, PG <= 15 + make flavors): reads a
  version-spec-keyed catalog `metadata.test` block. Exercised for inline contrib
  suites, schedule-driven core suites, dual-kind slugs, spec filtering, and the
  empty/`-running` edges.
- `suites_from_tests` (meson path, PG >= 16): a smoke test over a synthetic
  `.tests` array, locking the `--port`-trailing test extraction + kind classify.
- `suites_from_test_suites` (make path, the introspect-derived introspect):
  groups a flat list of pre-classified (slug, kind) SuiteDecls, covering the
  schedule, inline, dual-kind, and regress-only (version-exact gating) shapes.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/test:schema.bzl", _TestSchema = "schema")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _metadata_test_shapes_test_impl(ctx):
    env = unittest.begin(ctx)

    test_meta = {
        ">=15, <16": {
            "cube": {
                "kind": "regress",
                "tests": ["cube", "cube_sci"],
            },
            "regress": {
                "kind": "regress",
                "max_conc": 20,
                "schedule": "parallel_schedule",
                "tests": ["test_setup", "boolean", "char"],
            },
            "test_decoding": [
                {"kind": "regress", "tests": ["ddl", "xact"]},
                {"kind": "isolation", "tests": ["mxact"]},
            ],
        },
    }
    groups = _TestSchema.suites_from_metadata_test(test_meta, "15.0")
    asserts.equals(
        env,
        ["cube", "regress", "test_decoding"],
        sorted(groups.keys()),
    )

    # schedule-driven core regress: drives off the basename, not `--tests`; the
    # `tests` list only feeds `test_count` (sizing) + the 20-conn fan-out
    # marker.
    asserts.equals(env, 1, len(groups["regress"]))
    reg = groups["regress"][0]
    asserts.equals(env, "regress", reg.kind)
    asserts.true(env, reg.is_schedule)
    asserts.equals(env, "parallel_schedule", reg.schedule)
    asserts.equals(env, [], reg.test_names)
    asserts.equals(env, 3, reg.test_count)
    asserts.true(env, reg.uses_20conn)
    asserts.false(env, reg.has_initdb_template)
    asserts.equals(env, 0, reg.max_timeout)
    asserts.false(env, reg.is_running)

    # inline contrib: no schedule -> emits its ordered `--tests` list.
    cube = groups["cube"][0]
    asserts.false(env, cube.is_schedule)
    asserts.equals(env, None, cube.schedule)
    asserts.equals(env, ["cube", "cube_sci"], cube.test_names)
    asserts.equals(env, 2, cube.test_count)
    asserts.false(env, cube.uses_20conn)

    # dual-kind slug: regress is primary (index 0), isolation secondary (1).
    dk = groups["test_decoding"]
    asserts.equals(env, 2, len(dk))
    asserts.equals(env, "regress", dk[0].kind)
    asserts.equals(env, "isolation", dk[1].kind)
    asserts.equals(env, ["ddl", "xact"], dk[0].test_names)
    asserts.equals(env, ["mxact"], dk[1].test_names)

    return unittest.end(env)

metadata_test_shapes_test = unittest.make(_metadata_test_shapes_test_impl)

def _metadata_test_spec_filter_test_impl(ctx):
    env = unittest.begin(ctx)

    test_meta = {
        "*": {"always": {"kind": "regress", "tests": ["c"]}},
        ">=15, <16": {"only15": {"kind": "regress", "tests": ["a"]}},
        ">=16": {"only16plus": {"kind": "regress", "tests": ["b"]}},
    }

    # 15.0 matches `>=15, <16` and `*`, never `>=16`.
    g15 = _TestSchema.suites_from_metadata_test(test_meta, "15.0")
    asserts.equals(env, ["always", "only15"], sorted(g15.keys()))

    # 16.0 matches `>=16` and `*`, never `>=15, <16`.
    g16 = _TestSchema.suites_from_metadata_test(test_meta, "16.0")
    asserts.equals(env, ["always", "only16plus"], sorted(g16.keys()))

    return unittest.end(env)

metadata_test_spec_filter_test = unittest.make(
    _metadata_test_spec_filter_test_impl,
)

def _metadata_test_empty_test_impl(ctx):
    env = unittest.begin(ctx)

    # no block at all, and a block whose only spec misses this version, both
    # yield {} so write_test_version's `if not groups: continue` guard fires.
    asserts.equals(env, {}, _TestSchema.suites_from_metadata_test({}, "15.0"))
    asserts.equals(
        env,
        {},
        _TestSchema.suites_from_metadata_test(
            {">=16": {"x": {"kind": "regress", "tests": ["a"]}}},
            "15.0",
        ),
    )

    return unittest.end(env)

metadata_test_empty_test = unittest.make(_metadata_test_empty_test_impl)

def _metadata_test_exclude_tests_impl(ctx):
    env = unittest.begin(ctx)

    # A flat `exclude_tests` drops the named test on every base version; a
    # spec-keyed map drops it only on versions matching the spec.
    test_meta = {
        "*": {
            "byver": {
                "exclude_tests": {"<18": ["convert"]},
                "kind": "regress",
                "tests": {"*": ["convert", "store"]},
            },
            "flat": {
                "exclude_tests": ["dropped"],
                "kind": "regress",
                "tests": {"*": ["keep", "dropped"]},
            },
        },
    }

    g16 = _TestSchema.suites_from_metadata_test(test_meta, "16.0")
    asserts.equals(env, ["keep"], g16["flat"][0].test_names)
    asserts.equals(env, ["store"], g16["byver"][0].test_names)

    g18 = _TestSchema.suites_from_metadata_test(test_meta, "18.0")
    asserts.equals(env, ["keep"], g18["flat"][0].test_names)
    asserts.equals(env, ["convert", "store"], g18["byver"][0].test_names)

    # A suite emptied by exclude on one major is dropped there but survives
    # where the exclude does not match.
    empties = {
        "*": {
            "only18": {
                "exclude_tests": {"<18": ["a", "b"]},
                "kind": "regress",
                "tests": {"*": ["a", "b"]},
            },
        },
    }
    asserts.equals(env, {}, _TestSchema.suites_from_metadata_test(empties, "16.0"))
    asserts.equals(
        env,
        ["only18"],
        sorted(_TestSchema.suites_from_metadata_test(empties, "18.0").keys()),
    )

    return unittest.end(env)

metadata_test_exclude_tests_test = unittest.make(_metadata_test_exclude_tests_impl)

def _metadata_test_temp_instance_impl(ctx):
    env = unittest.begin(ctx)

    # An external regress decl's `temp_instance` names the suite's own
    # --temp-instance, relative to the extension source root.
    groups = _TestSchema.suites_from_metadata_test({
        "*": {
            "regress": {
                "kind": "regress",
                "temp_instance": "regress/instance",
                "tests": ["age_load", "index"],
            },
        },
    }, "16.11")
    asserts.equals(env, "regress/instance", groups["regress"][0].temp_instance)

    # a decl naming none takes the harness-private instance.
    plain = _TestSchema.suites_from_metadata_test(
        {"*": {"regress": {"kind": "regress", "tests": ["t"]}}},
        "16.11",
    )["regress"][0]
    asserts.equals(env, "", plain.temp_instance)

    return unittest.end(env)

metadata_test_temp_instance_test = unittest.make(_metadata_test_temp_instance_impl)

def _metadata_test_running_and_pure_isolation_test_impl(ctx):
    env = unittest.begin(ctx)

    test_meta = {"*": {
        "foo-running": {"kind": "regress", "tests": ["z"]},
        "isolation": {
            "kind": "isolation",
            "schedule": "isolation_schedule",
            "tests": ["x", "y"],
        },
    }}
    g = _TestSchema.suites_from_metadata_test(test_meta, "15.0")

    # a pure-isolation slug still keeps the bare (primary) slot.
    iso = g["isolation"][0]
    asserts.equals(env, "isolation", iso.kind)
    asserts.true(env, iso.is_schedule)
    asserts.equals(env, "isolation_schedule", iso.schedule)
    asserts.false(env, iso.is_running)

    # a `-running` slug is flagged so the override layer can filter it.
    asserts.true(env, g["foo-running"][0].is_running)

    return unittest.end(env)

metadata_test_running_and_pure_isolation_test = unittest.make(
    _metadata_test_running_and_pure_isolation_test_impl,
)

def _suites_from_tests_smoke_test_impl(ctx):
    env = unittest.begin(ctx)

    # synthetic meson `.tests` array: an inline contrib group + an isolation
    # group, mirroring the introspect testwrap shape.
    raw_tests = [
        {
            "cmd": ["/x/pg_regress", "--inputdir=.", "--port", "5432", "cube", "cube_sci"],
            "env": {},
            "is_parallel": True,
            "name": "cube",
            "protocol": "tap",
            "suite": ["postgresql:cube"],
            "timeout": 1000,
        },
        {
            "cmd": ["/x/pg_isolation_regress", "--port", "5432", "mxact"],
            "env": {},
            "is_parallel": False,
            "name": "test_decoding-isolation",
            "protocol": "tap",
            "suite": ["postgresql:test_decoding"],
            "timeout": 1000,
        },
    ]
    groups = _TestSchema.suites_from_tests(raw_tests)

    cube = groups["cube"][0]
    asserts.equals(env, "regress", cube.kind)
    asserts.false(env, cube.is_schedule)

    # the inline test names are the `--port <n>` trailing positionals.
    asserts.equals(env, ["cube", "cube_sci"], cube.test_names)

    asserts.equals(env, "isolation", groups["test_decoding"][0].kind)

    return unittest.end(env)

suites_from_tests_smoke_test = unittest.make(_suites_from_tests_smoke_test_impl)

def _suites_from_test_suites_test_impl(ctx):
    env = unittest.begin(ctx)

    # the make introspect's `test_suites` shape: a flat list of pre-classified
    # (slug, kind) entries (a dual-kind slug appears as two entries).
    test_suites = [
        {
            "kind": "regress",
            "max_conc": 20,
            "schedule": "parallel_schedule",
            "slug": "regress",
            "tests": ["test_setup", "boolean", "char"],
        },
        {"kind": "regress", "slug": "cube", "tests": ["cube", "cube_sci"]},
        {"kind": "regress", "slug": "test_decoding", "tests": ["ddl", "xact"]},
        {"kind": "isolation", "slug": "test_decoding", "tests": ["mxact"]},
        # postgres_fdw on a build that predates the eval_plan_qual back-patch:
        # only REGRESS is present, so NO isolation suite is emitted.
        {"kind": "regress", "slug": "postgres_fdw", "tests": ["postgres_fdw"]},
    ]
    groups = _TestSchema.suites_from_test_suites(test_suites)
    asserts.equals(
        env,
        ["cube", "postgres_fdw", "regress", "test_decoding"],
        sorted(groups.keys()),
    )

    # schedule-driven core regress: bare basename, 20-conn fan-out, no --tests.
    reg = groups["regress"][0]
    asserts.equals(env, "regress", reg.kind)
    asserts.true(env, reg.is_schedule)
    asserts.equals(env, "parallel_schedule", reg.schedule)
    asserts.equals(env, [], reg.test_names)
    asserts.equals(env, 3, reg.test_count)
    asserts.true(env, reg.uses_20conn)

    # inline contrib: ordered --tests, no schedule.
    cube = groups["cube"][0]
    asserts.false(env, cube.is_schedule)
    asserts.equals(env, ["cube", "cube_sci"], cube.test_names)

    # dual-kind slug groups into [regress (primary), isolation].
    dk = groups["test_decoding"]
    asserts.equals(env, 2, len(dk))
    asserts.equals(env, "regress", dk[0].kind)
    asserts.equals(env, "isolation", dk[1].kind)

    # version-exact gating: a regress-only slug yields exactly one (regress)
    # suite -- the make analog of 15.0's postgres_fdw lacking eval_plan_qual.
    pf = groups["postgres_fdw"]
    asserts.equals(env, 1, len(pf))
    asserts.equals(env, "regress", pf[0].kind)
    asserts.equals(env, ["postgres_fdw"], pf[0].test_names)

    return unittest.end(env)

suites_from_test_suites_test = unittest.make(_suites_from_test_suites_test_impl)

def _suites_from_test_suites_tap_test_impl(ctx):
    env = unittest.begin(ctx)

    # the make `test_suites` introspect carries each suite's source subtree,
    # plus `kind: tap` entries whose `tests` are the `.pl` basenames.
    test_suites = [
        {
            "kind": "regress",
            "schedule": "parallel_schedule",
            "slug": "regress",
            "subtree": "src/test/regress",
            "tests": ["boolean", "char"],
        },
        {
            "kind": "tap",
            "slug": "recovery",
            "subtree": "src/test/recovery",
            "tests": ["001_stream_rep", "002_archiving"],
        },
        {
            "kind": "tap",
            "slug": "pg_dump",
            "subtree": "src/bin/pg_dump",
            "tests": ["001_basic", "002_pg_dump"],
        },
    ]
    groups = _TestSchema.suites_from_test_suites(test_suites)

    # the subtree flows onto the SuiteInfo so the renderer mirrors the source
    # tree, and the core regress suite is categorized from its subtree.
    reg = groups["regress"][0]
    asserts.equals(env, "src/test/regress", reg.subtree)
    asserts.equals(env, _TestSchema.CAT_CORE, reg.category)

    # a TAP suite: its `.pl` basenames become `pl_names` (the TAP renderer emits
    # one target per .pl) while the inline pg_regress `test_names`/`dbname` stay
    # empty and the locale inherits, matching a meson TAP SuiteInfo. A TAP suite
    # under src/test is core, NOT treated as contrib by the slug heuristic.
    rec = groups["recovery"][0]
    asserts.equals(env, _TestSchema.KIND_TAP, rec.kind)
    asserts.equals(env, ["001_stream_rep", "002_archiving"], rec.pl_names)
    asserts.equals(env, [], rec.test_names)
    asserts.equals(env, "", rec.dbname)
    asserts.equals(env, "inherit", rec.locale_mode)
    asserts.equals(env, "src/test/recovery", rec.subtree)
    asserts.equals(env, _TestSchema.CAT_CORE, rec.category)

    # a TAP suite under src/bin is likewise core (its package mirrors to
    # bin/pg_dump/tap downstream), not contrib.
    pd = groups["pg_dump"][0]
    asserts.equals(env, _TestSchema.KIND_TAP, pd.kind)
    asserts.equals(env, ["001_basic", "002_pg_dump"], pd.pl_names)
    asserts.equals(env, _TestSchema.CAT_CORE, pd.category)

    return unittest.end(env)

suites_from_test_suites_tap_test = unittest.make(
    _suites_from_test_suites_tap_test_impl,
)

def _metadata_test_exclusive_impl(ctx):
    env = unittest.begin(ctx)

    # An external decl's `exclusive` carries two shapes over one key: a list of
    # `.pl` basenames picks individual TAP tests, `true` takes the whole suite,
    # which is the only lever a regress suite has (its tests share one target).
    test_meta = {
        "*": {
            "regress": {
                "exclusive": True,
                "kind": "regress",
                "tests": ["fifo_tests", "topic_tests"],
            },
            "tap": {
                "exclusive": ["030_histogram"],
                "kind": "tap",
                "tests": ["007_settings", "030_histogram"],
            },
        },
    }
    groups = _TestSchema.suites_from_metadata_test(test_meta, "16.11")

    # the whole-suite shape names no individual `.pl`, so the TAP renderer's
    # per-.pl lookup stays a list membership test either way.
    reg = groups["regress"][0]
    asserts.true(env, reg.exclusive_suite)
    asserts.equals(env, [], reg.tap_exclusive)

    tap = groups["tap"][0]
    asserts.equals(env, ["030_histogram"], tap.tap_exclusive)
    asserts.false(env, tap.exclusive_suite)

    # a decl naming neither shape: both default off.
    plain = _TestSchema.suites_from_metadata_test(
        {"*": {"regress": {"kind": "regress", "tests": ["t"]}}},
        "16.11",
    )["regress"][0]
    asserts.false(env, plain.exclusive_suite)
    asserts.equals(env, [], plain.tap_exclusive)

    return unittest.end(env)

metadata_test_exclusive_test = unittest.make(_metadata_test_exclusive_impl)

TEST_SUITE_NAME = "schema"

TEST_SUITE_TESTS = dict(
    metadata_test_empty = metadata_test_empty_test,
    metadata_test_exclude_tests = metadata_test_exclude_tests_test,
    metadata_test_exclusive = metadata_test_exclusive_test,
    metadata_test_running_and_pure_isolation = metadata_test_running_and_pure_isolation_test,
    metadata_test_shapes = metadata_test_shapes_test,
    metadata_test_spec_filter = metadata_test_spec_filter_test,
    metadata_test_temp_instance = metadata_test_temp_instance_test,
    suites_from_test_suites = suites_from_test_suites_test,
    suites_from_test_suites_tap = suites_from_test_suites_tap_test,
    suites_from_tests_smoke = suites_from_tests_smoke_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
