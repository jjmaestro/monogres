"""
Downstream pgext consumer contract tests (private e2e).

Three-phase pattern:
- Phase 1: load `@pg_ext//:all.bzl` via `cfg.bzl`; the load-time coherence
  check in `cfg.bzl` fails loading if any target's deps don't match repo
  metadata, so the load IS a coherence check.
- Phase 2: unittest invariants on the consumer-shape config (name,
  default_source labels, per-ext-version sources, target artifact + deps struct
  shape). Labels are baked; no string interpolation here.
- Phase 3: `build_test` on citus's default artifact + sysroot deps + a
  sample per-package dep label.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@pg_ext//:all.bzl", "KINDS")

def _invariants_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "citus", ctx.attr.name_check)

    # default_source has two labels: dir + files
    asserts.true(
        env,
        ctx.attr.default_source_dir.startswith("@pg_ext//citus/"),
        "default_source.dir = %r" % ctx.attr.default_source_dir,
    )
    asserts.true(
        env,
        ctx.attr.default_source_files.startswith("@pg_ext//citus/"),
        "default_source.files = %r" % ctx.attr.default_source_files,
    )

    # every source has a (version, dir, files) triple with labels scoped to the
    # per-ext-version package (@pg_ext//citus/{ext_v}:{dir,files}).
    for s in json.decode(ctx.attr.sources_json):
        asserts.true(env, s["version"] != "")
        asserts.equals(env, "@pg_ext//citus/%s:dir" % s["version"], s["dir"])
        asserts.equals(
            env,
            "@pg_ext//citus/%s:files" % s["version"],
            s["files"],
        )

    # every target carries a non-empty artifact label shaped as
    # @pg_ext//citus/{ext_v}/{base_v}:{base_v}
    for t in json.decode(ctx.attr.targets_json):
        asserts.equals(
            env,
            "@pg_ext//citus/%s/%s:%s" % (t["ext_version"], t["base_version"], t["base_version"]),
            t["artifact"],
        )

    # every deps entry has a consistent kind, sysroot, and packages count
    for d in json.decode(ctx.attr.deps_json):
        asserts.true(env, d["ext_version"] != "")
        asserts.true(env, d["base_version"] != "")
        asserts.true(env, d["kind"] in KINDS)

        # sysroot and packages are always-together (both present or both absent)
        if d["sysroot"]:
            asserts.true(
                env,
                d["sysroot"].startswith(
                    "@pg_ext//citus/%s/deps/%s:" % (d["ext_version"], d["kind"]),
                ),
                "unexpected sysroot %r" % d["sysroot"],
            )
            asserts.true(
                env,
                d["n_pkgs"] >= 1,
                "sysroot set but n_pkgs=%d" % d["n_pkgs"],
            )
        else:
            asserts.equals(env, 0, d["n_pkgs"])

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
    """Phase 2 + Phase 3 targets for the downstream consumer contract.

    Args:
        name: test-suite name.
        cfg: consumer-shape cfg struct (an entry from `cfg.bzl::CFGS[ext]`).
    """

    sources = [
        dict(version = s.version, dir = s.dir, files = s.files)
        for s in cfg.sources
    ]
    targets = [
        dict(
            ext_version = t.version,
            base_version = t.base_version.version,
            artifact = t.artifact,
        )
        for t in cfg.targets
    ]
    deps = []
    for t in cfg.targets:
        for kind in KINDS:
            kd = getattr(t.deps, kind)
            deps.append(dict(
                ext_version = t.version,
                base_version = t.base_version.version,
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

    # --- Phase 3: real build for the default target ---
    default_target = cfg.default
    build_targets = [default_target.artifact]
    for kind in KINDS:
        kd = getattr(default_target.deps, kind)
        if kd.sysroot:
            build_targets.append(kd.sysroot)
        if kd.packages:
            build_targets.append(kd.packages[0])

    # size reflects the weight of the underlying build, not the test action.
    build_test(
        name = "%s_build" % name,
        size = "large",
        timeout = "short",
        targets = build_targets,
    )
