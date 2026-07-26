"""
Unit tests for monoext/private/repo_names.bzl.

Pins the repo-naming conventions described in `repo_names.bzl` and validates
that `bind()` correctly formats label templates.

- `_`-joined role suffixes (`_src`, `_ext`, `_pkgs`, `_deb`) for one-per-parent
  roles
- `--` `INSTANCE_SEP` for many-per-parent instances (version, extension name),
  chosen so a single `-` inside an instance (e.g. a Debian version like
  `1:14.0.6-12`) stays unambiguous
- the PG per-version source repo uses a single `-` because
  `download_archives` owns that convention
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//monoext/private:repo_names.bzl", "bind", "repo_names")
load("//tests:suite.bzl", _test_suite = "test_suite")

# ---------------------------------------------------------------------------
# Repo name convention tests
# ---------------------------------------------------------------------------

def _role_suffix_single_underscore_test_impl(ctx):
    """Role suffixes are joined with a single `_`."""
    env = unittest.begin(ctx)

    asserts.equals(env, "pg_ext", repo_names.ext_hub("pg"))
    asserts.equals(env, "pg_pkgs", repo_names.pkgs_hub("pg"))
    asserts.equals(env, "pg_src", repo_names.base_src("pg"))
    asserts.equals(env, "pg_pkgs_deb", repo_names.deb_repo("pg_pkgs"))

    return unittest.end(env)

role_suffix_single_underscore_test = unittest.make(
    _role_suffix_single_underscore_test_impl,
)

def _base_src_version_single_dash_test_impl(ctx):
    """`download_archives` convention: per-version source repo uses a single `-`."""
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "pg_src-18.1",
        repo_names.base_src_version("pg", "18.1"),
    )
    asserts.equals(
        env,
        "pg_src-17.0",
        repo_names.base_src_version("pg", "17.0"),
    )

    return unittest.end(env)

base_src_version_single_dash_test = unittest.make(
    _base_src_version_single_dash_test_impl,
)

def _introspect_uses_double_dash_test_impl(ctx):
    """Per-version introspect uses `--` so a version with a single `-` stays unambiguous."""
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "pg_introspect--18.1",
        repo_names.pg_introspect("pg", "18.1"),
    )

    # A Debian-style version with a literal `-` still parses unambiguously: the
    # role boundary is `--`, everything after is the instance.
    asserts.equals(
        env,
        "pg_introspect--1:14.0.6-12",
        repo_names.pg_introspect("pg", "1:14.0.6-12"),
    )

    return unittest.end(env)

introspect_uses_double_dash_test = unittest.make(
    _introspect_uses_double_dash_test_impl,
)

def _ext_src_uses_double_dash_test_impl(ctx):
    """Per-extension source repo uses `--` between role and instance."""
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "pg_ext_src--citus",
        repo_names.ext_src("pg_ext", "citus"),
    )
    asserts.equals(
        env,
        "pg_ext_src--sslutils",
        repo_names.ext_src("pg_ext", "sslutils"),
    )

    return unittest.end(env)

ext_src_uses_double_dash_test = unittest.make(
    _ext_src_uses_double_dash_test_impl,
)

def _alternate_hub_name_test_impl(ctx):
    """All helpers compose correctly with a non-`pg` hub name."""
    env = unittest.begin(ctx)

    asserts.equals(env, "foo_ext", repo_names.ext_hub("foo"))
    asserts.equals(env, "foo_pkgs", repo_names.pkgs_hub("foo"))
    asserts.equals(env, "foo_src", repo_names.base_src("foo"))
    asserts.equals(
        env,
        "foo_src-18.1",
        repo_names.base_src_version("foo", "18.1"),
    )
    asserts.equals(
        env,
        "foo_introspect--18.1",
        repo_names.pg_introspect("foo", "18.1"),
    )
    asserts.equals(
        env,
        "foo_ext_src--citus",
        repo_names.ext_src(repo_names.ext_hub("foo"), "citus"),
    )
    asserts.equals(
        env,
        "foo_pkgs_deb",
        repo_names.deb_repo(repo_names.pkgs_hub("foo")),
    )

    return unittest.end(env)

alternate_hub_name_test = unittest.make(_alternate_hub_name_test_impl)

# ---------------------------------------------------------------------------
# bind() + inline label template tests
# ---------------------------------------------------------------------------

def _bind_basic_test_impl(ctx):
    """bind() creates a formatter that formats templates with the given context."""
    env = unittest.begin(ctx)

    f = bind(hub = "pg", v = "18.1", opt = "full")
    asserts.equals(env, "@pg//18.1/full:tar", f("@{hub}//{v}/{opt}:tar"))
    asserts.equals(
        env,
        "@pg//18.1/full:introspect",
        f("@{hub}//{v}/{opt}:introspect"),
    )
    asserts.equals(env, "@pg//18.1:dir", f("@{hub}//{v}:dir"))
    asserts.equals(env, "@pg//18.1:files", f("@{hub}//{v}:files"))
    asserts.equals(env, "@pg//18.1:toolchain", f("@{hub}//{v}:toolchain"))
    asserts.equals(env, "@pg//18.1", f("@{hub}//{v}"))

    return unittest.end(env)

bind_basic_test = unittest.make(_bind_basic_test_impl)

def _bind_extra_keys_ignored_test_impl(ctx):
    """bind() silently ignores context keys not present in the template."""
    env = unittest.begin(ctx)

    f = bind(hub = "pg", v = "18.1", opt = "full", arch = "amd64")
    asserts.equals(env, "@pg//18.1:dir", f("@{hub}//{v}:dir"))

    return unittest.end(env)

bind_extra_keys_ignored_test = unittest.make(_bind_extra_keys_ignored_test_impl)

def _pg_label_patterns_test_impl(ctx):
    """PG label patterns produce the expected labels via bind()."""
    env = unittest.begin(ctx)

    f = bind(hub = "pg", v = "18.1", opt = "full")

    # hub-qualified
    asserts.equals(env, "@pg//18.1/full:tar", f("@{hub}//{v}/{opt}:tar"))
    asserts.equals(
        env,
        "@pg//18.1/full:introspect",
        f("@{hub}//{v}/{opt}:introspect"),
    )

    # local
    f_local = bind(v = "18.1", opt = "full")
    asserts.equals(env, "//18.1/full:full", f_local("//{v}/{opt}:{opt}"))
    asserts.equals(env, "//18.1/src:dir", f_local("//{v}/src:dir"))
    asserts.equals(env, "//18.1/src:files", f_local("//{v}/src:files"))
    asserts.equals(
        env,
        "//18.1/full:toolchain",
        f_local("//{v}/{opt}:toolchain"),
    )
    asserts.equals(env, "//18.1/full:logs", f_local("//{v}/{opt}:logs"))
    asserts.equals(env, "//18.1/full:tar", f_local("//{v}/{opt}:tar"))

    # per-arch
    f_arch = bind(hub = "pg", v = "18.1", opt = "full", arch = "amd64")
    asserts.equals(
        env,
        "@pg//18.1/full/amd64:tar",
        f_arch("@{hub}//{v}/{opt}/{arch}:tar"),
    )

    # alternate hub name
    f_alt = bind(hub = "mypg", v = "17.0", opt = "regular")
    asserts.equals(
        env,
        "@mypg//17.0/regular:tar",
        f_alt("@{hub}//{v}/{opt}:tar"),
    )

    return unittest.end(env)

pg_label_patterns_test = unittest.make(_pg_label_patterns_test_impl)

def _ext_label_patterns_test_impl(ctx):
    """Extension label patterns produce the expected labels."""
    env = unittest.begin(ctx)

    # external artifact
    f = bind(hub = "pg_ext", ext = "citus", ext_v = "13.2.0", base_v = "18.1")
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/18.1:18.1",
        f("@{hub}//{ext}/{ext_v}/{base_v}:{base_v}"),
    )
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0:dir",
        f("@{hub}//{ext}/{ext_v}:dir"),
    )
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0:files",
        f("@{hub}//{ext}/{ext_v}:files"),
    )

    # contrib artifact
    f_contrib = bind(hub = "pg_ext", name = "pgcrypto", base_v = "18.1")
    asserts.equals(
        env,
        "@pg_ext//contrib/pgcrypto/18.1:tar",
        f_contrib("@{hub}//contrib/{name}/{base_v}:tar"),
    )

    # local
    f_local = bind(name = "citus", v = "13.2.0", base_v = "18.1", source = "gh")
    asserts.equals(
        env,
        "//citus/13.2.0/18.1:18.1",
        f_local("//{name}/{v}/{base_v}:{base_v}"),
    )
    asserts.equals(env, "//citus/13.2.0:dir", f_local("//{name}/{v}:dir"))
    asserts.equals(
        env,
        "//citus/13.2.0/src/gh:dir",
        f_local("//{name}/{v}/src/{source}:dir"),
    )
    asserts.equals(env, "//citus:repo.bzl", f_local("//{name}:repo.bzl"))

    f_local_contrib = bind(name = "pgcrypto", base_v = "18.1")
    asserts.equals(
        env,
        "//contrib/pgcrypto/18.1:tar",
        f_local_contrib("//contrib/{name}/{base_v}:tar"),
    )
    asserts.equals(
        env,
        "//contrib/pgcrypto:repo.bzl",
        f_local_contrib("//contrib/{name}:repo.bzl"),
    )

    # per-arch
    f_arch = bind(
        hub = "pg_ext",
        ext = "citus",
        ext_v = "13.2.0",
        base_v = "18.1",
        arch = "amd64",
    )
    asserts.equals(
        env,
        "@pg_ext//citus/13.2.0/18.1/amd64:18.1",
        f_arch("@{hub}//{ext}/{ext_v}/{base_v}/{arch}:{base_v}"),
    )

    f_contrib_arch = bind(
        hub = "pg_ext",
        name = "pgcrypto",
        base_v = "18.1",
        arch = "arm64",
    )
    asserts.equals(
        env,
        "@pg_ext//contrib/pgcrypto/18.1/arm64:tar",
        f_contrib_arch("@{hub}//contrib/{name}/{base_v}/{arch}:tar"),
    )

    return unittest.end(env)

ext_label_patterns_test = unittest.make(_ext_label_patterns_test_impl)

def _src_delegation_labels_test_impl(ctx):
    """Source repo delegation labels."""
    env = unittest.begin(ctx)

    f = bind(src = "pg_src", v = "18.1")
    asserts.equals(env, "@pg_src//18.1:dir", f("@{src}//{v}:dir"))
    asserts.equals(env, "@pg_src//18.1:files", f("@{src}//{v}:files"))
    asserts.equals(env, "@pg_src//18.1:18.1", f("@{src}//{v}:{v}"))
    asserts.equals(env, "@pg_src//18.1", f("@{src}//{v}"))
    f_ext = bind(src = "pg_ext_src--citus")
    asserts.equals(
        env,
        "@pg_ext_src--citus//:repo.bzl",
        f_ext("@{src}//:repo.bzl"),
    )
    asserts.equals(
        env,
        "@pg_ext_src--citus//:lock.json",
        f_ext("@{src}//:lock.json"),
    )

    f_ver = bind(src = "pg_src-18.1", v = "18.1", source = "gh")
    asserts.equals(
        env,
        "@pg_src-18.1//18.1/gh:BUILD.bazel",
        f_ver("@{src}//{v}/{source}:BUILD.bazel"),
    )

    return unittest.end(env)

src_delegation_labels_test = unittest.make(_src_delegation_labels_test_impl)

def _build_repo_load_labels_test_impl(ctx):
    """Build repo load labels."""
    env = unittest.begin(ctx)

    f = bind(build = "monogres")
    asserts.equals(
        env,
        "@monogres//monoext/private/base:pg_build.bzl",
        f("@{build}//monoext/private/base:pg_build.bzl"),
    )
    asserts.equals(
        env,
        "@monogres//monoext/private/ext/build:pgxs.bzl",
        f("@{build}//monoext/private/ext/build:pgxs.bzl"),
    )
    asserts.equals(
        env,
        "@monogres//platforms:platform_build.bzl",
        f("@{build}//platforms:platform_build.bzl"),
    )
    asserts.equals(
        env,
        "@monogres//utils:declare_outputs.bzl",
        f("@{build}//utils:declare_outputs.bzl"),
    )

    f_arch = bind(build = "monogres", arch = "amd64")
    asserts.equals(
        env,
        "@monogres//platforms:linux_amd64",
        f_arch("@{build}//platforms:linux_{arch}"),
    )

    return unittest.end(env)

build_repo_load_labels_test = unittest.make(_build_repo_load_labels_test_impl)

def _pkgs_deb_labels_test_impl(ctx):
    """Pkgs/deb label patterns."""
    env = unittest.begin(ctx)

    f_hub = bind(hub = "pg_pkgs", pkg = "libfoo")
    asserts.equals(
        env,
        "@pg_pkgs//deb/libfoo:libfoo",
        f_hub("@{hub}//deb/{pkg}:{pkg}"),
    )

    f_sk = bind(hub = "pg_pkgs", key = "sk0")
    asserts.equals(
        env,
        "@pg_pkgs//deb/sysroots:sk0",
        f_sk("@{hub}//deb/sysroots:{key}"),
    )

    f_repo = bind(repo = "pg_pkgs_deb", pkg = "libfoo")
    asserts.equals(
        env,
        "@pg_pkgs_deb//libfoo:libfoo",
        f_repo("@{repo}//{pkg}:{pkg}"),
    )

    f_repo_arch = bind(repo = "pg_pkgs_deb", pkg = "libfoo", arch = "amd64")
    asserts.equals(
        env,
        "@pg_pkgs_deb//libfoo/amd64:amd64",
        f_repo_arch("@{repo}//{pkg}/{arch}:{arch}"),
    )

    return unittest.end(env)

pkgs_deb_labels_test = unittest.make(_pkgs_deb_labels_test_impl)

def _introspect_labels_test_impl(ctx):
    """Introspect label patterns."""
    env = unittest.begin(ctx)

    f = bind(repo = "pg_introspect--18.1", opt = "full", v = "18.1", hub = "pg")
    asserts.equals(
        env,
        "@pg_introspect--18.1//full:defs.bzl",
        f("@{repo}//{opt}:defs.bzl"),
    )
    asserts.equals(
        env,
        "//:introspect/json/18.1/full/defs.bzl",
        f("//:introspect/json/{v}/{opt}/defs.bzl"),
    )
    asserts.equals(env, "@pg//18.1:toolchain", f("@{hub}//{v}:toolchain"))

    return unittest.end(env)

introspect_labels_test = unittest.make(_introspect_labels_test_impl)

# ---------------------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------------------

TEST_SUITE_NAME = "names"

TEST_SUITE_TESTS = dict(
    alternate_hub_name = alternate_hub_name_test,
    base_src_version_single_dash = base_src_version_single_dash_test,
    bind_basic = bind_basic_test,
    bind_extra_keys_ignored = bind_extra_keys_ignored_test,
    build_repo_load_labels = build_repo_load_labels_test,
    ext_label_patterns = ext_label_patterns_test,
    ext_src_uses_double_dash = ext_src_uses_double_dash_test,
    introspect_labels = introspect_labels_test,
    introspect_uses_double_dash = introspect_uses_double_dash_test,
    pg_label_patterns = pg_label_patterns_test,
    pkgs_deb_labels = pkgs_deb_labels_test,
    role_suffix_single_underscore = role_suffix_single_underscore_test,
    src_delegation_labels = src_delegation_labels_test,
)

test_suite = lambda: _test_suite(TEST_SUITE_NAME, TEST_SUITE_TESTS)
