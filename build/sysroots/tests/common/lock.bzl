"""
Unit tests for `//sysroots/common:lock.bzl`.

Round-trip encode / decode plus `validate` with matching and stale inputs.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//common:lock.bzl", _Lock = "lock")
load("//tests:suite.bzl", _test_suite = "test_suite")

_SAMPLE_PACKAGES = [
    {
        "arch": "amd64",
        "name": "libc6",
        "sha256": "abc123",
        "urls": ["https://example.com/libc6.deb"],
        "version": "2.36-9",
    },
    {
        "arch": "amd64",
        "name": "libssl3",
        "sha256": "def456",
        "urls": ["https://example.com/libssl3.deb"],
        "version": "3.0.0",
    },
]

def _make_lock():
    return _Lock.new(
        snapshot = "20250113T000000Z",
        archs = ["amd64", "arm64"],
        packages = _SAMPLE_PACKAGES,
        package_name_map = {"libssl-dev": "libssl3"},
    )

def _version_field_test_impl(ctx):
    """Lock data always has version = LOCK_VERSION."""
    env = unittest.begin(ctx)

    lock = _make_lock()
    asserts.equals(env, _Lock.LOCK_VERSION, lock.version)

    return unittest.end(env)

version_field_test = unittest.make(_version_field_test_impl)

def _serde_roundtrip_test_impl(ctx):
    """encode -> decode round-trip preserves all fields."""
    env = unittest.begin(ctx)

    original = _make_lock()
    decoded = _Lock.decode(_Lock.encode(original))

    asserts.equals(env, original.version, decoded.version)
    asserts.equals(env, original.snapshot, decoded.snapshot)
    asserts.equals(env, original.archs, decoded.archs)
    asserts.equals(env, original.packages, decoded.packages)
    asserts.equals(env, original.package_name_map, decoded.package_name_map)

    return unittest.end(env)

serde_roundtrip_test = unittest.make(_serde_roundtrip_test_impl)

def _validate_pass_test_impl(ctx):
    """Valid lock returns None."""
    env = unittest.begin(ctx)

    lock = _make_lock()
    error = _Lock.validate(
        lock,
        snapshot = "20250113T000000Z",
        archs = ["amd64", "arm64"],
        requested_packages = ["libc6", "libssl-dev"],
    )
    asserts.equals(env, None, error)

    return unittest.end(env)

validate_pass_test = unittest.make(_validate_pass_test_impl)

def _validate_stale_snapshot_test_impl(ctx):
    """Snapshot mismatch returns error."""
    env = unittest.begin(ctx)

    lock = _make_lock()
    error = _Lock.validate(
        lock,
        snapshot = "20260101T000000Z",
        archs = ["amd64", "arm64"],
        requested_packages = ["libc6"],
    )
    asserts.true(env, error != None)
    asserts.true(env, "snapshot mismatch" in error)

    return unittest.end(env)

validate_stale_snapshot_test = unittest.make(_validate_stale_snapshot_test_impl)

def _validate_missing_arch_test_impl(ctx):
    """Archs mismatch returns error."""
    env = unittest.begin(ctx)

    lock = _make_lock()
    error = _Lock.validate(
        lock,
        snapshot = "20250113T000000Z",
        archs = ["amd64", "arm64", "riscv64"],
        requested_packages = ["libc6"],
    )
    asserts.true(env, error != None)
    asserts.true(env, "archs mismatch" in error)

    return unittest.end(env)

validate_missing_arch_test = unittest.make(_validate_missing_arch_test_impl)

def _validate_missing_package_test_impl(ctx):
    """Missing package returns error."""
    env = unittest.begin(ctx)

    lock = _make_lock()
    error = _Lock.validate(
        lock,
        snapshot = "20250113T000000Z",
        archs = ["amd64", "arm64"],
        requested_packages = ["libc6", "libfoo-dev"],
    )
    asserts.true(env, error != None)
    asserts.true(env, "missing packages" in error)
    asserts.true(env, "libfoo-dev" in error)

    return unittest.end(env)

validate_missing_package_test = unittest.make(
    _validate_missing_package_test_impl,
)

def _validate_virtual_package_test_impl(ctx):
    """Virtual package resolved through package_name_map passes."""
    env = unittest.begin(ctx)

    lock = _make_lock()
    error = _Lock.validate(
        lock,
        snapshot = "20250113T000000Z",
        archs = ["amd64", "arm64"],
        requested_packages = ["libssl-dev"],
    )
    asserts.equals(env, None, error)

    return unittest.end(env)

validate_virtual_package_test = unittest.make(
    _validate_virtual_package_test_impl,
)

TEST_SUITE_NAME = "lock"

TEST_SUITE_TESTS = dict(
    version_field = version_field_test,
    serde_roundtrip = serde_roundtrip_test,
    validate_missing_arch = validate_missing_arch_test,
    validate_missing_package = validate_missing_package_test,
    validate_pass = validate_pass_test,
    validate_stale_snapshot = validate_stale_snapshot_test,
    validate_virtual_package = validate_virtual_package_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
