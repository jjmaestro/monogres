"""
Private e2e tests for the `@pg` hub.

Three phases (see README.md for more details):
- Phase 1: load `@pg//:all.bzl` + `@pg//:introspect.bzl` at BUILD time.
- Phase 2: unittest invariants on the loaded data.
- Phase 3: `build_test` on the default target (from `cfg.default.artifact`)
  plus its `:introspect` sibling (forces Layer-2 lazy fetch).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")

def _invariants_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, ctx.attr.expected_flavor, ctx.attr.cfg_name)
    asserts.equals(env, ctx.attr.default_version, ctx.attr.cfg_default_version)
    asserts.equals(
        env,
        ctx.attr.last_option_set,
        ctx.attr.cfg_default_option_set,
    )

    for t in json.decode(ctx.attr.targets_json):
        asserts.true(
            env,
            t["version"] in ctx.attr.versions,
            "unknown target version %r" % t["version"],
        )
        asserts.true(
            env,
            t["option_set"] in ctx.attr.option_sets,
            "unknown target option_set %r" % t["option_set"],
        )

    # Layer-1 introspect: every baked (version, option_set) references a known
    # version + option_set combo.
    for k in json.decode(ctx.attr.introspect_keys_json):
        asserts.true(env, k["version"] in ctx.attr.versions)
        asserts.true(env, k["option_set"] in ctx.attr.option_sets)

    return unittest.end(env)

_invariants_test = unittest.make(
    _invariants_test_impl,
    attrs = dict(
        cfg_name = attr.string(mandatory = True),
        cfg_default_version = attr.string(mandatory = True),
        cfg_default_option_set = attr.string(mandatory = True),
        default_version = attr.string(mandatory = True),
        expected_flavor = attr.string(mandatory = True),
        last_option_set = attr.string(mandatory = True),
        versions = attr.string_list(mandatory = True),
        option_sets = attr.string_list(mandatory = True),
        targets_json = attr.string(mandatory = True),
        introspect_keys_json = attr.string(mandatory = True),
    ),
)

def e2e_tests(
        name,
        cfg,
        versions,
        option_sets,
        default_version,
        introspections,
        expected_flavor):
    """Phase 2 + Phase 3 targets for a monoext base hub.

    Args:
        name: test-suite name.
        cfg: `CFG` struct from `@{name}//:all.bzl`.
        versions: `VERSIONS` list from `@{name}//:all.bzl`.
        option_sets: `OPTION_SETS` list from `@{name}//:all.bzl`.
        default_version: `DEFAULT_VERSION` from `@{name}//:all.bzl`.
        introspections: `INTROSPECTIONS` dict from `@{name}//:introspect.bzl`.
        expected_flavor: expected `cfg.name` (e.g. `"postgres"`, `"ivorysql"`).
    """

    targets = [
        dict(version = t.version, option_set = t.option_set)
        for t in cfg.targets
    ]
    introspect_keys = [
        dict(version = v, option_set = os)
        for (v, os) in introspections.keys()
    ]

    # --- Phase 2: invariants (unittest) ---
    _invariants_test(
        name = "%s_invariants" % name,
        cfg_name = cfg.name,
        cfg_default_version = cfg.default.version,
        cfg_default_option_set = cfg.default.option_set,
        default_version = default_version,
        expected_flavor = expected_flavor,
        last_option_set = option_sets[-1],
        versions = versions,
        option_sets = option_sets,
        targets_json = json.encode(targets),
        introspect_keys_json = json.encode(introspect_keys),
        size = "small",
    )

    # --- Phase 3: 1-2 real builds ---
    # size reflects the weight of the underlying build, not the test action.
    build_test(
        name = "%s_build" % name,
        size = "large",
        timeout = "short",
        targets = [
            cfg.default.artifact,
            cfg.default.introspect,
        ],
    )

def _required_contribs_test_impl(ctx):
    """Phase 2 assertion that named contribs appear in the introspect data.

    Used as a focused make-build integration test: confirms that overlay
    contribs (e.g. babelfish_extensions's `babelfishpg_*`) actually appear in
    the Layer-1 INTROSPECTIONS dict with non-empty paths after the end-to-end
    synth + Layer-1 stub pipeline. Catches regressions where the introspect
    synth drops contribs or misattributes file ownership.

    `INTROSPECTIONS` shape (passed via `introspections_json`): a dict keyed by
    `[version, option_set]` tuples, each value containing a `contrib` dict with
    per-contrib `paths` lists.
    """
    env = unittest.begin(ctx)

    target_key = (ctx.attr.version, ctx.attr.option_set)
    introspections = json.decode(ctx.attr.introspections_json)
    entry_key = json.encode([target_key[0], target_key[1]])
    entry = introspections.get(entry_key)
    asserts.true(
        env,
        entry != None,
        "(version=%r, option_set=%r) not in INTROSPECTIONS — got keys %r" %
        (target_key[0], target_key[1], list(introspections.keys())),
    )
    if entry == None:
        return unittest.end(env)

    contribs = entry.get("contrib", {})
    for name in ctx.attr.required_contribs:
        asserts.true(
            env,
            name in contribs,
            "contrib %r missing from INTROSPECTIONS[%s]" % (name, entry_key),
        )
        if name in contribs:
            paths = contribs[name].get("paths", [])
            asserts.true(
                env,
                len(paths) > 0,
                "contrib %r has empty paths list in INTROSPECTIONS[%s]" %
                (name, entry_key),
            )

    return unittest.end(env)

_required_contribs_test = unittest.make(
    _required_contribs_test_impl,
    attrs = dict(
        introspections_json = attr.string(mandatory = True),
        option_set = attr.string(mandatory = True),
        required_contribs = attr.string_list(mandatory = True),
        version = attr.string(mandatory = True),
    ),
)

def make_build_required_contribs_test(
        name,
        introspections,
        version,
        option_set,
        required_contribs):
    """End-to-end assertion for the autoconf+make introspect pipeline.

    Asserts that `introspections[(version, option_set)]` (from the hub's
    `@<flavor>//:introspect.bzl`) contains each of `required_contribs` with
    non-empty `paths`. The introspect data here comes from the synthesized JSONs
    checked in at `build/catalog/<flavor>/introspect/<...>.json` → Layer-1 paths
    repo → introspect.bzl, so the test exercises the whole synth → Layer-1 →
    consumer chain without needing the underlying build.

    Args:
        name: test target name.
        introspections: `INTROSPECTIONS` dict from `@<flavor>//:introspect.bzl`.
        version: base version to check (e.g. `"5.1"`).
        option_set: option set to check (e.g. `"full"`).
        required_contribs: contrib names that must be present with paths.
    """

    # The INTROSPECTIONS dict uses tuple keys which JSON can't represent. Re-key
    # with `json.encode(list)` of the tuple so the data passes through the test
    # rule's string attribute and reconstructs on the other side.
    flat = {
        json.encode([k[0], k[1]]): v
        for (k, v) in introspections.items()
    }
    _required_contribs_test(
        name = name,
        introspections_json = json.encode(flat),
        option_set = option_set,
        required_contribs = required_contribs,
        version = version,
        size = "small",
    )
