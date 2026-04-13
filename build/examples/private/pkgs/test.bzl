"""
Private e2e tests for the `@pg_pkgs` hub.

Validates a sample of resolved package metadata. The per-PG sysroot
materialization moved out of `@pg_pkgs` into `@pgbuildtime_<key>` hubs (Phase
3.4 deleted the `@pg_pkgs//deb/sysroots/...flatten(...)` pipeline); the per-PG
hubs are exercised end-to-end by the actual pg/pgxs builds under `@pg//...` and
`@pg_ext//...`.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

def _invariants_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.true(
        env,
        len(ctx.attr.packages) >= 1,
        "at least one sample package",
    )

    # every package has a non-empty version and at least one arch
    for p in json.decode(ctx.attr.package_info_json):
        asserts.true(env, p["package"] != "")
        asserts.true(env, p["version"] != "")
        asserts.true(env, len(p["archs"]) >= 1)

    return unittest.end(env)

_invariants_test = unittest.make(
    _invariants_test_impl,
    attrs = dict(
        packages = attr.string_list(mandatory = True),
        package_info_json = attr.string(mandatory = True),
    ),
)

def e2e_tests(name, packages):
    """Invariants over a sample of resolved `@pg_pkgs` packages.

    Args:
        name: test-suite name.
        packages: `{pkg: {archs: [...], version: ...}}`.
    """

    pkg_names = sorted(packages.keys())
    package_info = [
        dict(
            package = pkg,
            version = info["version"],
            archs = sorted(info["archs"]),
        )
        for pkg, info in sorted(packages.items())
    ]

    _invariants_test(
        name = "%s_invariants" % name,
        packages = pkg_names,
        package_info_json = json.encode(package_info),
        size = "small",
    )
