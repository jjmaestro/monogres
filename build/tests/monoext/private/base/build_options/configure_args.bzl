"""
Unit tests for monoext/private/base/build_options/configure_args.bzl.

Covers the Meson option name → autoconf flag translation across:
- `--with-X` boolean options (readline, zlib, icu, ldap, …)
- `--enable-X` boolean options (nls, tap_tests, cassert, …)
- string-valued `--with-X=VALUE` options (uuid, system_tzdata, extra_version)
- folded options (`readline` + `libedit_preferred` → `--with-readline=libedit`)
- signal-string options (`ssl=openssl` → `--with-openssl`,
  `plpython=true` → `--with-python`)
- prefix translation (`prefix_distro=<path>` → `--prefix=<path>`)
- explicitly-dropped Meson-only options (`auto_features`, `injection_points`,
  `spinlocks`, `atomics`, `rpath`, `b_coverage`, `libdir`)
- `contrib` is *not* a configure flag (autoconf uses make-target choice)
- end-to-end translation of a PG 15 `regular`-set options dict

Plus the small make-target helpers:
- `make_target_for(options)` → `[("", ["world-bin"])]` if `contrib=true` else
  `[("", ["all"])]`
- `make_install_target_for(options)` → `[("", ["install-world-bin"])]` / `[("",
  ["install"])]`

And the autoconf-extra-libs helper:
- `extra_libs_for(options)` → e.g. `["-ldns_sd"]` when bonjour is enabled
  (PG's autoconf does not add `-ldns_sd` to LIBS itself; caller must inject it
  into `Makefile.global` post-configure).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load(
    "//monoext/private/base/build_options:configure_args.bzl",
    "extra_libs_for",
    "make_install_target_for",
    "make_target_for",
    "to_configure_args",
)
load("//tests:suite.bzl", _test_suite = "test_suite")

# --- per-category coverage -------------------------------------------------

def _bool_with_truthy_test_impl(ctx):
    """`--with-X` for truthy boolean options."""
    env = unittest.begin(ctx)

    args = to_configure_args({"zlib": "enabled"})
    asserts.true(env, "--with-zlib" in args)

    args = to_configure_args({"icu": True})
    asserts.true(env, "--with-icu" in args)

    args = to_configure_args({"systemd": "true"})
    asserts.true(env, "--with-systemd" in args)

    return unittest.end(env)

bool_with_truthy_test = unittest.make(_bool_with_truthy_test_impl)

def _bool_with_falsy_test_impl(ctx):
    """`--without-X` for falsy boolean options."""
    env = unittest.begin(ctx)

    args = to_configure_args({"zlib": "disabled"})
    asserts.true(env, "--without-zlib" in args)

    args = to_configure_args({"systemd": False})
    asserts.true(env, "--without-systemd" in args)

    return unittest.end(env)

bool_with_falsy_test = unittest.make(_bool_with_falsy_test_impl)

def _bool_enable_test_impl(ctx):
    """`--enable-X` / `--disable-X` for non-`with` boolean options."""
    env = unittest.begin(ctx)

    args = to_configure_args({"nls": "enabled"})
    asserts.true(env, "--enable-nls" in args)

    args = to_configure_args({"nls": "disabled"})
    asserts.true(env, "--disable-nls" in args)

    args = to_configure_args({"tap_tests": "enabled"})
    asserts.true(env, "--enable-tap-tests" in args)

    args = to_configure_args({"cassert": "true"})
    asserts.true(env, "--enable-cassert" in args)

    return unittest.end(env)

bool_enable_test = unittest.make(_bool_enable_test_impl)

def _string_with_test_impl(ctx):
    """String-valued `--with-X=VALUE` options."""
    env = unittest.begin(ctx)

    args = to_configure_args({"uuid": "ossp"})
    asserts.true(env, "--with-uuid=ossp" in args)

    args = to_configure_args({"system_tzdata": "/usr/share/zoneinfo"})
    asserts.true(env, "--with-system-tzdata=/usr/share/zoneinfo" in args)

    args = to_configure_args({"extra_version": "regular"})
    asserts.true(env, "--with-extra-version=regular" in args)

    return unittest.end(env)

string_with_test = unittest.make(_string_with_test_impl)

# --- folded options --------------------------------------------------------

def _readline_alone_test_impl(ctx):
    """`readline=true` alone → `--with-readline` (default backend)."""
    env = unittest.begin(ctx)

    args = to_configure_args({"readline": "enabled"})
    asserts.true(env, "--with-readline" in args)
    asserts.true(env, "--with-readline=libedit" not in args)

    return unittest.end(env)

readline_alone_test = unittest.make(_readline_alone_test_impl)

def _readline_libedit_test_impl(ctx):
    """`readline=true` + `libedit_preferred=true` -> `--with-readline` (libedit_preferred ignored).

    PG's autoconf has only one `--with-readline` boolean flag (no
    `--with-readline=libedit` value form like Meson). `libedit_preferred` is
    dropped.
    """
    env = unittest.begin(ctx)

    args = to_configure_args({
        "libedit_preferred": "true",
        "readline": "enabled",
    })
    asserts.true(env, "--with-readline" in args)
    asserts.true(env, "--with-readline=libedit" not in args)

    return unittest.end(env)

readline_libedit_test = unittest.make(_readline_libedit_test_impl)

def _readline_disabled_test_impl(ctx):
    """`readline=false` → `--without-readline` (libedit_preferred ignored)."""
    env = unittest.begin(ctx)

    args = to_configure_args({
        "libedit_preferred": "true",
        "readline": "disabled",
    })
    asserts.true(env, "--without-readline" in args)

    return unittest.end(env)

readline_disabled_test = unittest.make(_readline_disabled_test_impl)

def _readline_disabled_alone_test_impl(ctx):
    """`readline=false` without `libedit_preferred` → `--without-readline`."""
    env = unittest.begin(ctx)

    args = to_configure_args({"readline": "disabled"})
    asserts.true(env, "--without-readline" in args)
    asserts.true(env, "--with-readline" not in args)

    return unittest.end(env)

readline_disabled_alone_test = unittest.make(_readline_disabled_alone_test_impl)

def _readline_libedit_falsy_test_impl(ctx):
    """`readline=true` + `libedit_preferred=false` → `--with-readline`.

    `libedit_preferred` does not influence the autoconf path either way; only
    `readline` matters.
    """
    env = unittest.begin(ctx)

    args = to_configure_args({
        "libedit_preferred": "false",
        "readline": "enabled",
    })
    asserts.true(env, "--with-readline" in args)
    asserts.true(env, "--with-readline=libedit" not in args)

    return unittest.end(env)

readline_libedit_falsy_test = unittest.make(_readline_libedit_falsy_test_impl)

def _libedit_preferred_without_readline_test_impl(ctx):
    """`libedit_preferred=true` without `readline` → no readline flag.

    `libedit_preferred` is folded into `readline` by `_readline_args` and should
    never emit on its own. Other unrelated args may still be present (the
    function always enumerates the full known boolean set with defaults); the
    assertion is that no `--*-readline` flag appears.
    """
    env = unittest.begin(ctx)

    args = to_configure_args({"libedit_preferred": "true"})
    for arg in args:
        asserts.true(
            env,
            "readline" not in arg,
            msg = "unexpected readline arg %r" % arg,
        )

    return unittest.end(env)

libedit_preferred_without_readline_test = unittest.make(
    _libedit_preferred_without_readline_test_impl,
)

def _readline_absent_test_impl(ctx):
    """Neither `readline` nor `libedit_preferred` set → no readline flag."""
    env = unittest.begin(ctx)

    args = to_configure_args({})
    for arg in args:
        asserts.true(
            env,
            "readline" not in arg,
            msg = "unexpected readline arg %r" % arg,
        )

    return unittest.end(env)

readline_absent_test = unittest.make(_readline_absent_test_impl)

# --- signal-string options -------------------------------------------------

def _ssl_openssl_test_impl(ctx):
    """`ssl=openssl` → `--with-openssl`."""
    env = unittest.begin(ctx)

    args = to_configure_args({"ssl": "openssl"})
    asserts.true(env, "--with-openssl" in args)

    # Other ssl backends (e.g. gnutls) don't translate; should not emit.
    args = to_configure_args({"ssl": "gnutls"})
    asserts.true(env, "--with-openssl" not in args)

    return unittest.end(env)

ssl_openssl_test = unittest.make(_ssl_openssl_test_impl)

def _plpython_test_impl(ctx):
    """`plpython=true` → `--with-python` (autoconf names the dep, not the PL)."""
    env = unittest.begin(ctx)

    args = to_configure_args({"plpython": "true"})
    asserts.true(env, "--with-python" in args)

    return unittest.end(env)

plpython_test = unittest.make(_plpython_test_impl)

def _plperl_pltcl_test_impl(ctx):
    """`plperl`/`pltcl` follow `plpython`: PL option name → interpreter dep flag.

    `plperl=true` → `--with-perl`, `pltcl=true` → `--with-tcl`. When absent the
    signal-string translation emits the explicit `--without-X` (the make-side
    analog of Meson auto-off), so `minimal`/`barebones` builds disable both PLs
    while `regular`/`full` enable them, matching the meson path's behavior.
    """
    env = unittest.begin(ctx)

    args = to_configure_args({"plperl": "true", "pltcl": "true"})
    asserts.true(env, "--with-perl" in args)
    asserts.true(env, "--with-tcl" in args)

    # absent -> explicit disable.
    args = to_configure_args({})
    asserts.true(env, "--without-perl" in args)
    asserts.true(env, "--without-tcl" in args)

    return unittest.end(env)

plperl_pltcl_test = unittest.make(_plperl_pltcl_test_impl)

# --- prefix translation ----------------------------------------------------

def _prefix_distro_test_impl(ctx):
    """`prefix_distro=<path>` → `--prefix=<path>` (path embedded in pg_config.h)."""
    env = unittest.begin(ctx)

    args = to_configure_args({"prefix_distro": "/postgres/15.0"})
    asserts.true(env, "--prefix=/postgres/15.0" in args)

    return unittest.end(env)

prefix_distro_test = unittest.make(_prefix_distro_test_impl)

# --- dropped options -------------------------------------------------------

def _meson_only_options_dropped_test_impl(ctx):
    """Meson-only options drop silently (no autoconf equivalent).

    The translator still emits default-disable flags for the standard boolean
    option set (so autoconf's built-in defaults are anchored), but *none* of
    those flags should reference Meson-only options (auto_features,
    injection_points, spinlocks, atomics, rpath, b_coverage, libdir, docs,
    docs_pdf).

    `docs` / `docs_pdf` are dropped because PG's autoconf has no
    `--disable-documentation` flag (configure would warn "unrecognized
    options"). Docs are skipped at *make-target* level instead — see
    `make_target_for`.
    """
    env = unittest.begin(ctx)

    args = to_configure_args({
        "atomics": "true",
        "auto_features": "enabled",
        "b_coverage": "false",
        "docs": "disabled",
        "docs_pdf": "disabled",
        "injection_points": "false",
        "libdir": "lib",
        "rpath": "false",
        "spinlocks": "true",
    })

    for opt in (
        "auto_features",
        "injection-points",
        "injection_points",
        "spinlocks",
        "atomics",
        "rpath",
        "b-coverage",
        "b_coverage",
        "libdir",
        "docs",
        "documentation",
        "pdf",
    ):
        for arg in args:
            asserts.true(
                env,
                opt not in arg,
                "Meson-only option %r leaked into autoconf flag %r" % (opt, arg),
            )

    return unittest.end(env)

meson_only_options_dropped_test = unittest.make(
    _meson_only_options_dropped_test_impl,
)

# --- contrib is target-level, not a configure flag ------------------------

def _contrib_is_not_a_flag_test_impl(ctx):
    """`contrib=true` does not emit a `./configure` flag (target-level)."""
    env = unittest.begin(ctx)

    args = to_configure_args({"contrib": "true"})

    # No flag should reference `contrib`.
    for arg in args:
        asserts.true(env, "contrib" not in arg)

    return unittest.end(env)

contrib_is_not_a_flag_test = unittest.make(
    _contrib_is_not_a_flag_test_impl,
)

# --- make target selection -------------------------------------------------

def _make_target_with_contrib_test_impl(ctx):
    """`contrib=true` -> `world-bin` / `install-world-bin` (core + contrib, no docs)."""
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        [("", ["world-bin"])],
        make_target_for({"contrib": "true"}),
    )
    asserts.equals(
        env,
        [("", ["install-world-bin"])],
        make_install_target_for({"contrib": "true"}),
    )

    return unittest.end(env)

make_target_with_contrib_test = unittest.make(
    _make_target_with_contrib_test_impl,
)

def _make_target_without_contrib_test_impl(ctx):
    """No `contrib` (or falsy) -> `all` / `install` (core only)."""
    env = unittest.begin(ctx)

    asserts.equals(env, [("", ["all"])], make_target_for({}))
    asserts.equals(env, [("", ["install"])], make_install_target_for({}))

    asserts.equals(env, [("", ["all"])], make_target_for({"contrib": "false"}))
    asserts.equals(
        env,
        [("", ["install"])],
        make_install_target_for({"contrib": "false"}),
    )

    return unittest.end(env)

make_target_without_contrib_test = unittest.make(
    _make_target_without_contrib_test_impl,
)

def _extra_libs_bonjour_test_impl(ctx):
    """`bonjour=enabled` -> `["-ldns_sd"]` to append to LIBS post-configure.

    PG's autoconf path probes for `dns_sd.h` only and deliberately does not
    auto-link `-ldns_sd` (see `configure.ac` near the bonjour stanza). The
    caller has to inject the link flag for non-Apple builds — appended to
    `Makefile.global`'s `LIBS` *after* configure runs, so configure probes don't
    get polluted with the avahi/dbus transitive chain.
    """
    env = unittest.begin(ctx)

    asserts.equals(env, ["-ldns_sd"], extra_libs_for({"bonjour": "enabled"}))
    asserts.equals(env, ["-ldns_sd"], extra_libs_for({"bonjour": "true"}))

    # Disabled / missing -> no extra libs
    asserts.equals(env, [], extra_libs_for({"bonjour": "disabled"}))
    asserts.equals(env, [], extra_libs_for({}))

    return unittest.end(env)

extra_libs_bonjour_test = unittest.make(_extra_libs_bonjour_test_impl)

# --- end-to-end PG 15 regular-set translation ------------------------------

def _pg15_regular_set_test_impl(ctx):
    """End-to-end: a PG 15 `regular`-set options dict translates correctly."""
    env = unittest.begin(ctx)

    options = {
        "contrib": "true",
        "extra_version": "regular",
        "icu": "enabled",
        "libdir": "lib",
        "libedit_preferred": "true",
        "llvm": "enabled",
        "lz4": "enabled",
        "nls": "enabled",
        "plperl": "true",
        "plpython": "true",
        "pltcl": "true",
        "prefix_distro": "/postgres/15.0",
        "readline": "enabled",
        "rpath": "false",
        "ssl": "openssl",
        "system_tzdata": "/usr/share/zoneinfo",
        "systemd": "enabled",
        "uuid": "ossp",
        "zlib": "enabled",
        "zstd": "enabled",
    }

    args = to_configure_args(options)

    expected_present = [
        "--prefix=/postgres/15.0",
        "--with-readline",
        "--enable-nls",
        "--with-zlib",
        "--with-icu",
        "--with-llvm",
        "--with-lz4",
        "--with-zstd",
        "--with-systemd",
        "--with-openssl",
        "--with-perl",
        "--with-python",
        "--with-tcl",
        "--with-uuid=ossp",
        "--with-system-tzdata=/usr/share/zoneinfo",
        "--with-extra-version=regular",
    ]
    for flag in expected_present:
        asserts.true(env, flag in args, "missing %r in %r" % (flag, args))

    expected_absent = [
        # `contrib` is target-level, not a flag.
        "--with-contrib",
        "--enable-contrib",
        # `libdir` / `rpath` are dropped.
        "--libdir=lib",
        "--with-rpath",
        # libedit_preferred isn't a separate flag — autoconf only has the
        # boolean `--with-readline`.
        "--with-readline=libedit",
    ]
    for flag in expected_absent:
        asserts.true(
            env,
            flag not in args,
            "unexpected %r in %r" % (flag, args),
        )

    return unittest.end(env)

pg15_regular_set_test = unittest.make(_pg15_regular_set_test_impl)

TEST_SUITE_NAME = "configure_args"

TEST_SUITE_TESTS = dict(
    bool_enable = bool_enable_test,
    bool_with_falsy = bool_with_falsy_test,
    bool_with_truthy = bool_with_truthy_test,
    contrib_is_not_a_flag = contrib_is_not_a_flag_test,
    extra_libs_bonjour = extra_libs_bonjour_test,
    make_target_with_contrib = make_target_with_contrib_test,
    make_target_without_contrib = make_target_without_contrib_test,
    meson_only_options_dropped = meson_only_options_dropped_test,
    pg15_regular_set = pg15_regular_set_test,
    plperl_pltcl = plperl_pltcl_test,
    plpython = plpython_test,
    prefix_distro = prefix_distro_test,
    libedit_preferred_without_readline = libedit_preferred_without_readline_test,
    readline_absent = readline_absent_test,
    readline_alone = readline_alone_test,
    readline_disabled = readline_disabled_test,
    readline_disabled_alone = readline_disabled_alone_test,
    readline_libedit = readline_libedit_test,
    readline_libedit_falsy = readline_libedit_falsy_test,
    ssl_openssl = ssl_openssl_test,
    string_with = string_with_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
