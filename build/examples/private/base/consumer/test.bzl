"""
Downstream pg consumer contract tests (private e2e).

Three-phase pattern:
- Phase 1: load `@pg//:all.bzl` via `cfg.bzl`; the load-time coherence check
  in `cfg.bzl` fails loading if any target's deps / artifact / source is
  malformed, so the load IS a coherence check.
- Phase 2: unittest invariants on the consumer-shape config (name,
  default_source labels, per-version sources, per-target artifact + deps struct
  shape). With labels now baked into CFG, no string interpolation happens here —
  the test just walks `target.artifact`, `target.source.*`, `target.deps.*`.
- Phase 3: `build_test` on the default target + each populated kind's deps
  labels (buildtime/runtime/test × sysroot/sample-package); a kind with no
  declared deps (e.g. an empty `test`) is skipped.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@pg//:all.bzl", "KINDS")

def _invariants_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "postgres", ctx.attr.name_check)

    # default_source has two labels: dir + files
    asserts.true(
        env,
        ctx.attr.default_source_dir.startswith("@pg//"),
        "default_source.dir = %r" % ctx.attr.default_source_dir,
    )
    asserts.true(
        env,
        ctx.attr.default_source_files.startswith("@pg//"),
        "default_source.files = %r" % ctx.attr.default_source_files,
    )

    # every source has a (version, dir, files) triple with labels scoped to the
    # version package (@pg//{version}:{dir,files}).
    for s in json.decode(ctx.attr.sources_json):
        asserts.true(env, s["version"] != "")
        asserts.equals(env, "@pg//%s:dir" % s["version"], s["dir"])
        asserts.equals(env, "@pg//%s:files" % s["version"], s["files"])

    # every target carries a non-empty artifact label under @pg//
    for t in json.decode(ctx.attr.targets_json):
        asserts.true(env, t["version"] != "")
        asserts.true(env, t["option_set"] != "")
        asserts.equals(
            env,
            "@pg//%s/%s:tar" % (t["version"], t["option_set"]),
            t["artifact"],
        )

    # every emitted deps entry (empty kinds are filtered out in e2e_tests) has a
    # consistent kind, non-empty sysroot, and at least one package label.
    for d in json.decode(ctx.attr.deps_json):
        asserts.true(env, d["kind"] in KINDS)
        asserts.equals(
            env,
            "@pg//%s/deps/%s:sysroot" % (d["version"], d["kind"]),
            d["sysroot"],
        )
        asserts.true(env, d["n_pkgs"] >= 1, "n_pkgs=%s" % d["n_pkgs"])

    return unittest.end(env)

_invariants_test = unittest.make(
    _invariants_test_impl,
    attrs = dict(
        name_check = attr.string(mandatory = True),
        default_source_dir = attr.string(mandatory = True),
        default_source_files = attr.string(mandatory = True),
        sources_json = attr.string(mandatory = True),
        targets_json = attr.string(mandatory = True),
        deps_json = attr.string(mandatory = True),
    ),
)

def e2e_tests(name, cfg):
    """Phase 2 + Phase 3 targets for the downstream pg consumer contract.

    Args:
        name: test-suite name.
        cfg: the consumer-shape config struct (from `cfg.bzl::CONSUMER_CFG`).
    """

    sources = [
        dict(version = s.version, dir = s.dir, files = s.files)
        for s in cfg.sources
    ]
    targets = [
        dict(
            version = t.version,
            option_set = t.option_set,
            artifact = t.artifact,
        )
        for t in cfg.targets
    ]
    deps = []
    for t in cfg.targets:
        for kind in KINDS:
            kd = getattr(t.deps, kind)
            if not kd.sysroot:
                continue  # kind not declared for this target (e.g. empty `test`)
            deps.append(dict(
                version = t.version,
                option_set = t.option_set,
                kind = kind,
                sysroot = kd.sysroot or "",
                n_pkgs = len(kd.packages),
            ))

    _invariants_test(
        name = "%s_invariants" % name,
        name_check = cfg.name,
        default_source_dir = cfg.default_source.dir,
        default_source_files = cfg.default_source.files,
        sources_json = json.encode(sources),
        targets_json = json.encode(targets),
        deps_json = json.encode(deps),
        size = "small",
    )

    # --- Phase 3: real build for the default target + its deps ---
    default_target = cfg.default
    build_targets = [default_target.artifact]
    for kind in KINDS:
        kd = getattr(default_target.deps, kind)
        if not kd.sysroot:
            continue  # kind not declared for this target (e.g. empty `test`)
        build_targets.append(kd.sysroot)
        build_targets.append(kd.packages[0])

    # size reflects the weight of the underlying build, not the test action.
    build_test(
        name = "%s_build" % name,
        size = "large",
        timeout = "short",
        targets = build_targets,
    )
