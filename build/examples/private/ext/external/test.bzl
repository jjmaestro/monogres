"""
Private e2e tests for `@pg_ext` external extensions.

Three-phase pattern:
- Phase 1: load `@pg_ext//:all.bzl` CFGS / EXTENSIONS / REPOS at BUILD time.
- Phase 2: unittest invariants on every extension's config and repo metadata.
  Artifact labels are now baked on each target; this test walks them straight
  out of `cfg.default.artifact` / `target.artifact`.
- Phase 3: `build_test` on citus's default artifact (via
  `cfg.default.artifact`).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")

def _invariants_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, sorted(ctx.attr.extensions), ctx.attr.extensions)
    asserts.true(
        env,
        len(ctx.attr.extensions) >= 1,
        "EXTENSIONS must have at least one entry",
    )

    # every extension must have at least one cfg and a non-empty cfg_name
    for ext in ctx.attr.extensions:
        asserts.true(
            env,
            ext in ctx.attr.cfg_names,
            "no CFGS[%r]" % ext,
        )
        asserts.equals(env, ext, ctx.attr.cfg_names[ext])

    # per-target structure: ext known, versions non-empty, artifact label shape
    for t in json.decode(ctx.attr.targets_json):
        asserts.true(
            env,
            t["ext"] in ctx.attr.extensions,
            "unknown extension %r" % t["ext"],
        )
        asserts.true(
            env,
            t["ext_version"] != "",
            "blank ext_version for %s" % t["ext"],
        )
        asserts.true(
            env,
            t["base_version"] != "",
            "blank base_version for %s/%s" % (t["ext"], t["ext_version"]),
        )
        asserts.equals(
            env,
            "@pg_ext//%s/%s/%s:%s" % (t["ext"], t["ext_version"], t["base_version"], t["base_version"]),
            t["artifact"],
        )

    # every ext has repo metadata with the mandatory fields
    repos = json.decode(ctx.attr.repos_json)
    for ext in ctx.attr.extensions:
        asserts.true(env, ext in repos, "missing REPOS[%r]" % ext)
        r = repos[ext]
        asserts.true(
            env,
            len(r["versions"]) >= 1,
            "REPOS[%r].versions empty" % ext,
        )
        asserts.true(
            env,
            r["default_version"] != "",
            "REPOS[%r].default_version blank" % ext,
        )
        asserts.true(
            env,
            r["repo_name"] != "",
            "REPOS[%r].repo_name blank" % ext,
        )

    return unittest.end(env)

_invariants_test = unittest.make(
    _invariants_test_impl,
    attrs = dict(
        extensions = attr.string_list(mandatory = True),
        cfg_names = attr.string_dict(mandatory = True),
        targets_json = attr.string(mandatory = True),
        repos_json = attr.string(mandatory = True),
    ),
)

def e2e_tests(name, cfgs, extensions, repos):
    """Phase 2 + Phase 3 targets for `@pg_ext` externals.

    Args:
        name: test-suite name.
        cfgs: `CFGS` from `@pg_ext//:all.bzl`.
        extensions: `EXTENSIONS` list from `@pg_ext//:all.bzl`.
        repos: `REPOS` dict from `@pg_ext//:all.bzl`.
    """

    targets = [
        dict(
            ext = ext,
            ext_version = target.version,
            base_version = target.base_version.version,
            artifact = target.artifact,
        )
        for ext in extensions
        for cfg in cfgs[ext]
        for target in cfg.targets
    ]

    cfg_names = {ext: cfgs[ext][0].name for ext in extensions}

    repos_out = {
        ext: dict(
            versions = sorted(repos[ext].versions),
            default_version = repos[ext].default_version,
            repo_name = repos[ext].repo_name,
        )
        for ext in extensions
    }

    _invariants_test(
        name = "%s_invariants" % name,
        extensions = extensions,
        cfg_names = cfg_names,
        targets_json = json.encode(targets),
        repos_json = json.encode(repos_out),
        size = "small",
    )

    # --- Phase 3: 1-2 real builds ---
    # size reflects the weight of the underlying build, not the test action.
    citus_default = cfgs["citus"][0].default
    build_test(
        name = "%s_build" % name,
        size = "large",
        timeout = "short",
        targets = [citus_default.artifact],
    )
