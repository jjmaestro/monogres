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

    asserts.equals(env, "postgres", ctx.attr.cfg_name)
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
        last_option_set = attr.string(mandatory = True),
        versions = attr.string_list(mandatory = True),
        option_sets = attr.string_list(mandatory = True),
        targets_json = attr.string(mandatory = True),
        introspect_keys_json = attr.string(mandatory = True),
    ),
)

def e2e_tests(name, cfg, versions, option_sets, default_version, introspections):
    """Phase 2 + Phase 3 targets for @pg.

    Args:
        name: test-suite name.
        cfg: `CFG` struct from `@pg//:all.bzl`.
        versions: `VERSIONS` list from `@pg//:all.bzl`.
        option_sets: `OPTION_SETS` list from `@pg//:all.bzl`.
        default_version: `DEFAULT_VERSION` from `@pg//:all.bzl`.
        introspections: `INTROSPECTIONS` dict from `@pg//:introspect.bzl`.
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
