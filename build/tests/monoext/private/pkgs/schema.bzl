"""
Unit tests for build/monoext/private/pkgs/schema.bzl.

Round-trips every type through `json.encode(...)` →
`from_dict(json.decode(...))` to pin the serde invariant, plus spot-checks
`new()` defaults, the "`None` for missing optional" convention on `DepsInfo`,
and the `TargetDeps.qualify()` projection that bakes `@hub//...` alias labels
onto each kind.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private/pkgs:schema.bzl", _PkgsSchema = "schema")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _di(packages):
    return _PkgsSchema.DepsInfo.new(
        packages = packages,
        pkgs_labels = [
            "@pg_pkgs//deb/%s:%s" % (p, p)
            for p in packages
        ],
        sysroot_labels_by_arch = {
            "amd64": "@pgbuildtime-abc//debian/12/amd64:sysroot",
            "arm64": "@pgbuildtime-abc//debian/12/arm64:sysroot",
        },
        sysroot_tar_labels_by_arch = {
            "amd64": "@pgbuildtime-abc//debian/12/amd64:sysroot.tar",
            "arm64": "@pgbuildtime-abc//debian/12/arm64:sysroot.tar",
        },
    )

def _deps_info_new_test_impl(ctx):
    env = unittest.begin(ctx)

    di = _PkgsSchema.DepsInfo.new(
        packages = ["libssl-dev"],
        pkgs_labels = ["@pkgs//deb/libssl-dev:libssl-dev"],
        sysroot_labels_by_arch = {
            "amd64": "@pgbuildtime-abc//debian/12/amd64:sysroot",
        },
        sysroot_tar_labels_by_arch = {
            "amd64": "@pgbuildtime-abc//debian/12/amd64:sysroot.tar",
        },
    )
    asserts.equals(env, ["libssl-dev"], di.packages)
    asserts.equals(env, 1, len(di.pkgs_labels))
    asserts.equals(
        env,
        {"amd64": "@pgbuildtime-abc//debian/12/amd64:sysroot"},
        di.sysroot_labels_by_arch,
    )
    asserts.equals(
        env,
        {"amd64": "@pgbuildtime-abc//debian/12/amd64:sysroot.tar"},
        di.sysroot_tar_labels_by_arch,
    )

    return unittest.end(env)

deps_info_new_test = unittest.make(_deps_info_new_test_impl)

def _deps_info_defaults_test_impl(ctx):
    env = unittest.begin(ctx)

    di = _PkgsSchema.DepsInfo.new()
    asserts.equals(env, [], di.packages)
    asserts.equals(env, [], di.pkgs_labels)
    asserts.equals(env, {}, di.sysroot_labels_by_arch)
    asserts.equals(env, {}, di.sysroot_tar_labels_by_arch)

    return unittest.end(env)

deps_info_defaults_test = unittest.make(_deps_info_defaults_test_impl)

def _deps_info_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    original = _PkgsSchema.DepsInfo.new(
        packages = ["libssl-dev", "libc6-dev"],
        pkgs_labels = [
            "@pkgs//deb/libssl-dev:libssl-dev",
            "@pkgs//deb/libc6-dev:libc6-dev",
        ],
        sysroot_labels_by_arch = {
            "amd64": "@pgbuildtime-abc//debian/12/amd64:sysroot",
            "arm64": "@pgbuildtime-abc//debian/12/arm64:sysroot",
        },
        sysroot_tar_labels_by_arch = {
            "amd64": "@pgbuildtime-abc//debian/12/amd64:sysroot.tar",
            "arm64": "@pgbuildtime-abc//debian/12/arm64:sysroot.tar",
        },
    )
    decoded = _PkgsSchema.DepsInfo.from_dict(
        json.decode(json.encode(original)),
    )
    asserts.equals(env, original, decoded)

    return unittest.end(env)

deps_info_roundtrip_test = unittest.make(_deps_info_roundtrip_test_impl)

def _deps_info_from_empty_test_impl(ctx):
    """from_dict returns None for empty/None inputs (optional presence)."""
    env = unittest.begin(ctx)

    asserts.equals(env, None, _PkgsSchema.DepsInfo.from_dict({}))
    asserts.equals(env, None, _PkgsSchema.DepsInfo.from_dict(None))

    return unittest.end(env)

deps_info_from_empty_test = unittest.make(_deps_info_from_empty_test_impl)

def _version_deps_new_test_impl(ctx):
    env = unittest.begin(ctx)

    vd = _PkgsSchema.VersionDeps.new()
    asserts.equals(env, None, vd.buildtime)
    asserts.equals(env, None, vd.runtime)

    bt = _PkgsSchema.DepsInfo.new(packages = ["libc6-dev"])
    rt = _PkgsSchema.DepsInfo.new(packages = ["libc6"])
    vd = _PkgsSchema.VersionDeps.new(buildtime = bt, runtime = rt)
    asserts.equals(env, bt, vd.buildtime)
    asserts.equals(env, rt, vd.runtime)

    return unittest.end(env)

version_deps_new_test = unittest.make(_version_deps_new_test_impl)

def _version_deps_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    original = _PkgsSchema.VersionDeps.new(
        buildtime = _PkgsSchema.DepsInfo.new(
            packages = ["libssl-dev"],
            pkgs_labels = ["@pkgs//deb/libssl-dev:libssl-dev"],
            sysroot_labels_by_arch = {
                "amd64": "@pgbuildtime-bt//debian/12/amd64:sysroot",
            },
            sysroot_tar_labels_by_arch = {
                "amd64": "@pgbuildtime-bt//debian/12/amd64:sysroot.tar",
            },
        ),
        runtime = _PkgsSchema.DepsInfo.new(
            packages = ["libssl3"],
            pkgs_labels = ["@pkgs//deb/libssl3:libssl3"],
            sysroot_labels_by_arch = {
                "amd64": "@pgbuildtime-rt//debian/12/amd64:sysroot",
            },
            sysroot_tar_labels_by_arch = {
                "amd64": "@pgbuildtime-rt//debian/12/amd64:sysroot.tar",
            },
        ),
    )
    decoded = _PkgsSchema.VersionDeps.from_dict(
        json.decode(json.encode(original)),
    )
    asserts.equals(env, original, decoded)

    return unittest.end(env)

version_deps_roundtrip_test = unittest.make(_version_deps_roundtrip_test_impl)

def _version_deps_from_empty_test_impl(ctx):
    """from_dict returns zero-value (not None) for empty/None inputs."""
    env = unittest.begin(ctx)

    vd = _PkgsSchema.VersionDeps.from_dict({})
    asserts.equals(env, _PkgsSchema.VersionDeps.new(), vd)

    vd2 = _PkgsSchema.VersionDeps.from_dict(None)
    asserts.equals(env, _PkgsSchema.VersionDeps.new(), vd2)

    return unittest.end(env)

version_deps_from_empty_test = unittest.make(_version_deps_from_empty_test_impl)

def _target_deps_defaults_test_impl(ctx):
    """new() with no args yields both kinds empty (sysroot=None, packages=[])."""
    env = unittest.begin(ctx)

    td = _PkgsSchema.TargetDeps.new()
    asserts.equals(env, None, td.buildtime.sysroot)
    asserts.equals(env, None, td.buildtime.sysroot_tar)
    asserts.equals(env, [], td.buildtime.packages)
    asserts.equals(env, None, td.runtime.sysroot)
    asserts.equals(env, None, td.runtime.sysroot_tar)
    asserts.equals(env, [], td.runtime.packages)

    return unittest.end(env)

target_deps_defaults_test = unittest.make(_target_deps_defaults_test_impl)

def _target_deps_qualify_both_kinds_test_impl(ctx):
    """Populated buildtime + runtime → qualified sysroot and packages for both."""
    env = unittest.begin(ctx)

    vd = _PkgsSchema.VersionDeps.new(
        buildtime = _di(["libssl-dev", "libzstd-dev"]),
        runtime = _di(["libssl3", "libzstd1"]),
    )
    td = _PkgsSchema.TargetDeps.qualify("@pg//18.1", vd)

    asserts.equals(
        env,
        "@pg//18.1/deps/buildtime:sysroot",
        td.buildtime.sysroot,
    )
    asserts.equals(
        env,
        "@pg//18.1/deps/buildtime:sysroot_tar",
        td.buildtime.sysroot_tar,
    )
    asserts.equals(
        env,
        [
            "@pg//18.1/deps/buildtime/pkgs:libssl-dev",
            "@pg//18.1/deps/buildtime/pkgs:libzstd-dev",
        ],
        td.buildtime.packages,
    )

    asserts.equals(env, "@pg//18.1/deps/runtime:sysroot", td.runtime.sysroot)
    asserts.equals(
        env,
        "@pg//18.1/deps/runtime:sysroot_tar",
        td.runtime.sysroot_tar,
    )
    asserts.equals(
        env,
        [
            "@pg//18.1/deps/runtime/pkgs:libssl3",
            "@pg//18.1/deps/runtime/pkgs:libzstd1",
        ],
        td.runtime.packages,
    )

    return unittest.end(env)

target_deps_qualify_both_kinds_test = unittest.make(
    _target_deps_qualify_both_kinds_test_impl,
)

def _target_deps_qualify_only_buildtime_test_impl(ctx):
    """Only buildtime populated → runtime kind is empty."""
    env = unittest.begin(ctx)

    vd = _PkgsSchema.VersionDeps.new(buildtime = _di(["libssl-dev"]))
    td = _PkgsSchema.TargetDeps.qualify("@pg_ext//citus/13.2.0", vd)

    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/deps/buildtime:sysroot",
        td.buildtime.sysroot,
    )
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/deps/buildtime:sysroot_tar",
        td.buildtime.sysroot_tar,
    )
    asserts.equals(
        env,
        ["@pg_ext//citus/13.2.0/deps/buildtime/pkgs:libssl-dev"],
        td.buildtime.packages,
    )

    asserts.equals(env, None, td.runtime.sysroot)
    asserts.equals(env, None, td.runtime.sysroot_tar)
    asserts.equals(env, [], td.runtime.packages)

    return unittest.end(env)

target_deps_qualify_only_buildtime_test = unittest.make(
    _target_deps_qualify_only_buildtime_test_impl,
)

def _target_deps_qualify_only_runtime_test_impl(ctx):
    """Only runtime populated → buildtime kind is empty."""
    env = unittest.begin(ctx)

    vd = _PkgsSchema.VersionDeps.new(runtime = _di(["libssl3"]))
    td = _PkgsSchema.TargetDeps.qualify("@pg//17.7", vd)

    asserts.equals(env, None, td.buildtime.sysroot)
    asserts.equals(env, None, td.buildtime.sysroot_tar)
    asserts.equals(env, [], td.buildtime.packages)

    asserts.equals(env, "@pg//17.7/deps/runtime:sysroot", td.runtime.sysroot)
    asserts.equals(
        env,
        "@pg//17.7/deps/runtime:sysroot_tar",
        td.runtime.sysroot_tar,
    )
    asserts.equals(
        env,
        ["@pg//17.7/deps/runtime/pkgs:libssl3"],
        td.runtime.packages,
    )

    return unittest.end(env)

target_deps_qualify_only_runtime_test = unittest.make(
    _target_deps_qualify_only_runtime_test_impl,
)

def _target_deps_qualify_empty_version_deps_test_impl(ctx):
    """Empty VersionDeps(None, None) → both kinds empty."""
    env = unittest.begin(ctx)

    td = _PkgsSchema.TargetDeps.qualify(
        "@pg//18.1",
        _PkgsSchema.VersionDeps.new(),
    )
    asserts.equals(env, None, td.buildtime.sysroot)
    asserts.equals(env, None, td.buildtime.sysroot_tar)
    asserts.equals(env, [], td.buildtime.packages)
    asserts.equals(env, None, td.runtime.sysroot)
    asserts.equals(env, None, td.runtime.sysroot_tar)
    asserts.equals(env, [], td.runtime.packages)

    return unittest.end(env)

target_deps_qualify_empty_version_deps_test = unittest.make(
    _target_deps_qualify_empty_version_deps_test_impl,
)

def _target_deps_qualify_none_version_deps_test_impl(ctx):
    """version_deps = None → same zero shape as an empty VersionDeps."""
    env = unittest.begin(ctx)

    td = _PkgsSchema.TargetDeps.qualify("@pg_ext//myext/1.0", None)
    asserts.equals(env, None, td.buildtime.sysroot)
    asserts.equals(env, None, td.buildtime.sysroot_tar)
    asserts.equals(env, [], td.buildtime.packages)
    asserts.equals(env, None, td.runtime.sysroot)
    asserts.equals(env, None, td.runtime.sysroot_tar)
    asserts.equals(env, [], td.runtime.packages)

    return unittest.end(env)

target_deps_qualify_none_version_deps_test = unittest.make(
    _target_deps_qualify_none_version_deps_test_impl,
)

def _target_deps_qualify_preserves_package_order_test_impl(ctx):
    """Packages render in input order (qualify does not sort)."""
    env = unittest.begin(ctx)

    vd = _PkgsSchema.VersionDeps.new(
        buildtime = _di(["zlib1g-dev", "libssl-dev", "libzstd-dev"]),
    )
    td = _PkgsSchema.TargetDeps.qualify("@pg//18.1", vd)

    asserts.equals(
        env,
        [
            "@pg//18.1/deps/buildtime/pkgs:zlib1g-dev",
            "@pg//18.1/deps/buildtime/pkgs:libssl-dev",
            "@pg//18.1/deps/buildtime/pkgs:libzstd-dev",
        ],
        td.buildtime.packages,
    )

    return unittest.end(env)

target_deps_qualify_preserves_package_order_test = unittest.make(
    _target_deps_qualify_preserves_package_order_test_impl,
)

def _target_deps_roundtrip_test_impl(ctx):
    """qualify() output round-trips through JSON unchanged."""
    env = unittest.begin(ctx)

    vd = _PkgsSchema.VersionDeps.new(
        buildtime = _di(["libssl-dev"]),
        runtime = _di(["libssl3"]),
    )
    original = _PkgsSchema.TargetDeps.qualify("@pg//18.1", vd)
    decoded = _PkgsSchema.TargetDeps.from_dict(
        json.decode(json.encode(original)),
    )
    asserts.equals(env, original, decoded)

    return unittest.end(env)

target_deps_roundtrip_test = unittest.make(_target_deps_roundtrip_test_impl)

def _target_deps_from_empty_test_impl(ctx):
    """from_dict returns zero-value TargetDeps for empty/None inputs."""
    env = unittest.begin(ctx)

    zero = _PkgsSchema.TargetDeps.new()
    asserts.equals(env, zero, _PkgsSchema.TargetDeps.from_dict({}))
    asserts.equals(env, zero, _PkgsSchema.TargetDeps.from_dict(None))

    return unittest.end(env)

target_deps_from_empty_test = unittest.make(_target_deps_from_empty_test_impl)

def _pkgs_result_roundtrip_test_impl(ctx):
    env = unittest.begin(ctx)

    bt = _PkgsSchema.DepsInfo.new(
        packages = ["libssl-dev"],
        pkgs_labels = ["@pkgs//deb/libssl-dev:libssl-dev"],
        sysroot_labels_by_arch = {
            "amd64": "@pgbuildtime-bt//debian/12/amd64:sysroot",
        },
        sysroot_tar_labels_by_arch = {
            "amd64": "@pgbuildtime-bt//debian/12/amd64:sysroot.tar",
        },
    )
    original = _PkgsSchema.PkgsResult.new(
        package_name_map = {"virt": "real"},
        versions_deps = {
            "citus": {
                "13.2.0": _PkgsSchema.VersionDeps.new(
                    buildtime = bt,
                    runtime = None,
                ),
            },
            "postgres": {
                "18.1": _PkgsSchema.VersionDeps.new(buildtime = bt),
            },
        },
    )
    decoded = _PkgsSchema.PkgsResult.from_dict(
        json.decode(json.encode(original)),
    )
    asserts.equals(env, original.package_name_map, decoded.package_name_map)
    asserts.equals(
        env,
        original.versions_deps["postgres"]["18.1"],
        decoded.versions_deps["postgres"]["18.1"],
    )
    asserts.equals(
        env,
        original.versions_deps["citus"]["13.2.0"],
        decoded.versions_deps["citus"]["13.2.0"],
    )

    return unittest.end(env)

pkgs_result_roundtrip_test = unittest.make(_pkgs_result_roundtrip_test_impl)

def _pkgs_result_from_empty_test_impl(ctx):
    env = unittest.begin(ctx)

    r = _PkgsSchema.PkgsResult.from_dict({})
    asserts.equals(env, {}, r.package_name_map)
    asserts.equals(env, {}, r.versions_deps)

    r2 = _PkgsSchema.PkgsResult.from_dict(None)
    asserts.equals(env, {}, r2.package_name_map)
    asserts.equals(env, {}, r2.versions_deps)

    return unittest.end(env)

pkgs_result_from_empty_test = unittest.make(_pkgs_result_from_empty_test_impl)

TEST_SUITE_NAME = "schema"

TEST_SUITE_TESTS = dict(
    deps_info_defaults = deps_info_defaults_test,
    deps_info_from_empty = deps_info_from_empty_test,
    deps_info_new = deps_info_new_test,
    deps_info_roundtrip = deps_info_roundtrip_test,
    pkgs_result_from_empty = pkgs_result_from_empty_test,
    pkgs_result_roundtrip = pkgs_result_roundtrip_test,
    target_deps_defaults = target_deps_defaults_test,
    target_deps_from_empty = target_deps_from_empty_test,
    target_deps_qualify_both_kinds = target_deps_qualify_both_kinds_test,
    target_deps_qualify_empty_version_deps = target_deps_qualify_empty_version_deps_test,
    target_deps_qualify_none_version_deps = target_deps_qualify_none_version_deps_test,
    target_deps_qualify_only_buildtime = target_deps_qualify_only_buildtime_test,
    target_deps_qualify_only_runtime = target_deps_qualify_only_runtime_test,
    target_deps_qualify_preserves_package_order = target_deps_qualify_preserves_package_order_test,
    target_deps_roundtrip = target_deps_roundtrip_test,
    version_deps_from_empty = version_deps_from_empty_test,
    version_deps_new = version_deps_new_test,
    version_deps_roundtrip = version_deps_roundtrip_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
