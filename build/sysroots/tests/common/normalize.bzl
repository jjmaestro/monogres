"""
Unit tests for `//sysroots/common:normalize.bzl`.

The rctx-using wrappers (`relativize_symlinks`, `rewrite_ld_scripts`) are
exercised end-to-end by the examples workspace under `examples/`; this file
tests the pure-Starlark helpers (`relativize_target`, `is_ld_script_text`) that
decide what to rewrite.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//common:normalize.bzl", _normalize = "normalize")
load("//tests:suite.bzl", _test_suite = "test_suite")

def _relativize_target_absolute_test_impl(ctx):
    """Pre-extract absolute target gets sysroot-rooted then relativized."""
    env = unittest.begin(ctx)

    # Bazel's `rctx.extract` usually pre-rewrites Debian absolute symlink
    # targets to be sysroot-rooted, but if a pre-extract `/lib/<arch>/…` form
    # reaches us, we treat it as relative-to-sysroot, then make it relative to
    # the symlink's directory.
    asserts.equals(
        env,
        "../../../lib/x86_64-linux-gnu/libpam.so.0",
        _normalize.relativize_target(
            "/foo/sysroot",
            "/foo/sysroot/usr/lib/x86_64-linux-gnu/libpam.so",
            "/lib/x86_64-linux-gnu/libpam.so.0",
        ),
    )
    return unittest.end(env)

relativize_target_absolute_test = unittest.make(
    _relativize_target_absolute_test_impl,
)

def _relativize_target_relative_test_impl(ctx):
    """Already-relative target is returned as None (no rewrite needed)."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        None,
        _normalize.relativize_target(
            "/foo/sysroot",
            "/foo/sysroot/usr/lib/libfoo.so",
            "../something",
        ),
    )
    asserts.equals(
        env,
        None,
        _normalize.relativize_target(
            "/foo/sysroot",
            "/foo/sysroot/usr/lib/libfoo.so",
            "libfoo.so.1",
        ),
    )
    return unittest.end(env)

relativize_target_relative_test = unittest.make(
    _relativize_target_relative_test_impl,
)

def _relativize_target_already_under_sysroot_test_impl(ctx):
    """Target already sysroot-rooted (rctx.extract's output) gets relativized."""
    env = unittest.begin(ctx)

    # The common case: `rctx.extract` has pre-rewritten the Debian target
    # `/lib/<arch>/libc.so.6` to `<sysroot_dir>/lib/<arch>/libc.so.6`. The
    # rewrite makes it sysroot-rooted but still absolute, which dangles under
    # any bind-mount. We finish the job by relativizing it.
    asserts.equals(
        env,
        "../../../lib/x86_64-linux-gnu/libc.so.6",
        _normalize.relativize_target(
            "/foo/sysroot",
            "/foo/sysroot/usr/lib/x86_64-linux-gnu/libc.so",
            "/foo/sysroot/lib/x86_64-linux-gnu/libc.so.6",
        ),
    )

    # Edge case: target equals the sysroot dir itself.
    asserts.equals(
        env,
        "..",
        _normalize.relativize_target(
            "/foo/sysroot",
            "/foo/sysroot/usr/foo",
            "/foo/sysroot",
        ),
    )

    # Sibling absolute path NOT under the sysroot: prefix-with-sysroot then
    # relativize. The result climbs above the sysroot's actual root, a
    # weird-but-deterministic case that the upstream Debian `.deb` symlink table
    # is unlikely to ever produce, but we handle it deterministically rather
    # than letting it propagate as a non-portable absolute path.
    asserts.equals(
        env,
        "../../foo/sysroot2/lib/libc.so.6",
        _normalize.relativize_target(
            "/foo/sysroot",
            "/foo/sysroot/usr/lib/libc.so",
            "/foo/sysroot2/lib/libc.so.6",
        ),
    )

    return unittest.end(env)

relativize_target_already_under_sysroot_test = unittest.make(
    _relativize_target_already_under_sysroot_test_impl,
)

def _relativize_target_same_dir_test_impl(ctx):
    """Target in the same directory as the symlink reduces to the basename."""
    env = unittest.begin(ctx)

    # Versioned-soname symlinks (`libfoo.so` → `libfoo.so.1`) typically sit next
    # to their target. After relativization the target becomes just the
    # basename, the same form Debian itself ships in many packages.
    asserts.equals(
        env,
        "libfoo.so.1",
        _normalize.relativize_target(
            "/foo/sysroot",
            "/foo/sysroot/usr/lib/libfoo.so",
            "/foo/sysroot/usr/lib/libfoo.so.1",
        ),
    )
    return unittest.end(env)

relativize_target_same_dir_test = unittest.make(
    _relativize_target_same_dir_test_impl,
)

def _is_ld_script_text_magic_test_impl(ctx):
    """`/*` is the GNU-ld linker-script magic."""
    env = unittest.begin(ctx)
    asserts.true(env, _normalize.is_ld_script_text("/*"))
    return unittest.end(env)

is_ld_script_text_magic_test = unittest.make(_is_ld_script_text_magic_test_impl)

def _is_ld_script_text_elf_test_impl(ctx):
    """Bytes other than the `/*` magic are not linker-script text."""
    env = unittest.begin(ctx)

    # First two bytes of an ELF file (\\x7f then 'E'), common .so binary.
    asserts.false(env, _normalize.is_ld_script_text("\177E"))

    # PE/COFF magic.
    asserts.false(env, _normalize.is_ld_script_text("MZ"))

    # Truncated reads.
    asserts.false(env, _normalize.is_ld_script_text(""))
    asserts.false(env, _normalize.is_ld_script_text("/"))

    return unittest.end(env)

is_ld_script_text_elf_test = unittest.make(_is_ld_script_text_elf_test_impl)

TEST_SUITE_NAME = "normalize"

TEST_SUITE_TESTS = dict(
    is_ld_script_text_elf = is_ld_script_text_elf_test,
    is_ld_script_text_magic = is_ld_script_text_magic_test,
    relativize_target_absolute = relativize_target_absolute_test,
    relativize_target_already_under_sysroot = relativize_target_already_under_sysroot_test,
    relativize_target_relative = relativize_target_relative_test,
    relativize_target_same_dir = relativize_target_same_dir_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
