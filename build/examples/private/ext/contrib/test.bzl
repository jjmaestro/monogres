"""
Private e2e tests for `@pg_ext` contrib extensions.

Three-phase pattern:
- Phase 1: load `@pg_ext//:all.bzl` CFGS_CONTRIB / CONTRIB_EXTENSIONS.
- Phase 2: unittest invariants on every contrib's config. Artifact labels
  are now baked on each contrib target (no inline interpolation).
- Phase 3: `build_test` on one contrib's default PG target via
  `cfg.default.artifact`.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")

def _invariants_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, sorted(ctx.attr.contribs), ctx.attr.contribs)
    asserts.true(
        env,
        len(ctx.attr.contribs) >= 1,
        "CONTRIB_EXTENSIONS must have at least one entry",
    )

    for ext in ctx.attr.contribs:
        asserts.true(
            env,
            ext in ctx.attr.cfg_names,
            "missing CFGS_CONTRIB[%r]" % ext,
        )
        asserts.equals(env, ext, ctx.attr.cfg_names[ext])

    for t in json.decode(ctx.attr.targets_json):
        asserts.true(
            env,
            t["ext"] in ctx.attr.contribs,
            "unknown contrib %r" % t["ext"],
        )
        asserts.true(
            env,
            t["base_version"] != "",
            "blank base_version for %s" % t["ext"],
        )
        asserts.equals(
            env,
            "@pg_ext//contrib/%s/%s:tar" % (t["ext"], t["base_version"]),
            t["artifact"],
        )

    return unittest.end(env)

_invariants_test = unittest.make(
    _invariants_test_impl,
    attrs = dict(
        contribs = attr.string_list(mandatory = True),
        cfg_names = attr.string_dict(mandatory = True),
        targets_json = attr.string(mandatory = True),
    ),
)

def e2e_tests(name, cfgs_contrib, contribs):
    """Phase 2 + Phase 3 targets for `@pg_ext` contribs.

    Args:
        name: test-suite name.
        cfgs_contrib: `CFGS_CONTRIB` from `@pg_ext//:all.bzl`.
        contribs: `CONTRIB_EXTENSIONS` list from `@pg_ext//:all.bzl`.
    """
    if not contribs:
        return

    targets = [
        dict(
            ext = ext,
            base_version = target.base_version.version,
            artifact = target.artifact,
        )
        for ext in contribs
        for cfg in cfgs_contrib[ext]
        for target in cfg.targets
    ]

    cfg_names = {ext: cfgs_contrib[ext][0].name for ext in contribs}

    _invariants_test(
        name = "%s_invariants" % name,
        contribs = contribs,
        cfg_names = cfg_names,
        targets_json = json.encode(targets),
        size = "small",
    )

    # --- Phase 3: 1-2 real builds ---
    if contribs:
        first_contrib = contribs[0]
        default_target = cfgs_contrib[first_contrib][0].default

        # size reflects the weight of the underlying build, not the test action.
        build_test(
            name = "%s_build" % name,
            size = "large",
            timeout = "short",
            targets = [default_target.artifact],
        )
