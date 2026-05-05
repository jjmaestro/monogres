"""
Rules to build Postgres from source using rules_foreign_cc.

This module defines the `pg_build` macro, which wraps the [`rules_foreign_cc`
`meson` rule] to build Postgres from source. It sets up the required environment
variables, toolchain references, and Meson options needed for the build.

[`rules_foreign_cc` `meson` rule]: https://bazel-contrib.github.io/rules_foreign_cc/meson.html
"""

load("@rules_foreign_cc//foreign_cc:meson.bzl", "meson")
load("//toolchains/llvm_sysroot:llvm_version.bzl", "LLVM_MAJOR")
load("//toolchains/perl:perl_toolchain.bzl", _PERL_VERSION = "PERL_VERSION")
load(":toolchain.bzl", "pg_template_variable_info")

# Action-time setup script: extracts the per-PG sysroot tar into
# `$EXT_BUILD_ROOT/sysroot/`, sed-patches perl's `Config.pm` / `Config_heavy.pl`
# in place for the hermetic chroot, symlinks the @libc_sysroot clang wrapper
# into the extracted tree (so meson canonicalizes the symlink into the wrapper's
# persistent absolute path when baking `CLANG` into `Makefile.global`), and
# prints the sysroot absolute path on stdout for `SYSROOT_DIR`.
_SYSROOT_SETUP_SCRIPT = "@monogres//monoext/private/base:sysroot_setup.sh"

# Per-arch @libc_sysroot clang wrapper. Cross-PG-version label — the wrapper
# content is the same for every buildtime sysroot (it's the same
# self-discovering shim from `//toolchains/libc_sysroot/clang_wrapper.sh`), so
# we anchor on the canonical @libc_sysroot copy rather than each per-PG
# `@pgbuildtime_<key>`'s sibling extra_files-injected copy. Meson canonicalizes
# the action-time symlink into this label's resolved file path, which lives
# under `/external/sysroots++sysroots+libc_sysroot/...` (persistent under
# Bazel's install-base bind-mount).
_SYSROOT_CLANG_WRAPPER = "@monogres//toolchains/libc_sysroot:active_clang_wrapper"

# `//toolchains/perl:perl` is the per-arch alias for the Perl interpreter binary
# (the per-arch `perl_toolchain` instance's `DefaultInfo` is the perl binary
# File + the @perl_sysroot tree as runfiles). Mirrors `@bison//bin:bison` /
# `@m4//bin:m4` shape: a single-file label addressable via `$(execpath ...)`.
# `//toolchains/perl:current_perl_toolchain` is the resolver, going in the
# `toolchains = [...]` list to satisfy the `TemplateVariableInfo` constraint and
# trigger toolchain resolution. Same shape as the rules_m4 / rules_flex /
# rules_bison `current_*_toolchain` entries.
#
# The ABI lockstep Postgres's plperl build requires (interpreter running
# `plperl_opmask.pl`, libperl.so / perl.h linked into plperl.so, libperl.so.5.36
# loaded at production runtime) is enforced by `@perl_sysroot` + the per-PG
# sysroot both sourcing from the same `APT_SNAPSHOT`. See
# `//toolchains/perl/README.md`.
_PERL_BIN = "@monogres//toolchains/perl:perl"
_PERL_TOOLCHAIN = "@monogres//toolchains/perl:current_perl_toolchain"

# `Config_overrides.pm` overrides `$Config{archlib}` / `$Config{archlibexp}` to
# point at the per-PG sysroot's libperl-dev `CORE/` dir at action time. Without
# it, `ExtUtils::Embed::ldopts` emits `-L<HOST path>/CORE -lperl`
# (@perl_sysroot's `Config.pm` reports Debian's compiled-in HOST paths under
# `/usr/lib/<cpu>-linux-gnu/...`, which don't exist in the hermetic sandbox).
# Loaded via `PERL5OPT='-MConfig_overrides'`; needs `PERL_DEBIAN_ARCHLIB` env
# var. Both are set in `env_sysroot` so the shim only fires when a per-PG
# sysroot is in scope.
_PERL_CONFIG_OVERRIDES = "@monogres//monoext/private/base:Config_overrides.pm"

# `//toolchains/python:python3` is the per-arch alias to the Debian python3
# interpreter (its `DefaultInfo` carries the full `@python_sysroot` tree as
# runfiles, so the stdlib + `libpython` ride into the action sandbox);
# `:current_python_toolchain` is the resolver going in `toolchains = [...]`.
# `@python_sysroot` is ABI-locked with the per-PG sysroot's `libpython` (both
# from the same snapshot), so meson's `find_installation()` and the per-PG
# `python-<ver>-embed.pc` agree at the same MAJOR.MINOR. Mirrors
# `@perl_sysroot`.
_PYTHON_BIN = "@monogres//toolchains/python:python3"
_PYTHON_TOOLCHAIN = "@monogres//toolchains/python:current_python_toolchain"

def _meson_common_args(pg_src, build_options, auto_features, sysroot_tar = None):
    build_data = [
        "@m4//bin:m4",
        "@flex//bin:flex",
        "@bison//bin:bison",
        _PYTHON_BIN,
        # `_PERL_BIN` is the per-arch alias to the perl interpreter (its
        # underlying target's `DefaultInfo` is the perl binary File plus the
        # full @perl_sysroot tree as runfiles, so the sibling
        # `usr/lib/<cpu>-linux-gnu/perl-base`, `perl/5.36`, and
        # `share/perl/5.36` dirs ride along into the action sandbox).
        # `_PERL_CONFIG_OVERRIDES` is the `archlibexp` / `privlibexp` shim,
        # loaded via `PERL5OPT` when a per-PG sysroot is in scope.
        _PERL_BIN,
        _PERL_CONFIG_OVERRIDES,
    ]

    if sysroot_tar:
        # The tar is the only `:sysroot_tar` artifact consumers see; the full
        # normalized tree lives inside. At action time the setup script extracts
        # it, sed-patches perl Config, and symlinks the clang wrapper. The
        # wrapper label is added separately because meson's canonicalize-symlink
        # step needs to resolve it to a persistent absolute path (not the
        # sandbox-extracted copy).
        build_data.append(sysroot_tar)
        build_data.append(_SYSROOT_CLANG_WRAPPER)
        build_data.append(_SYSROOT_SETUP_SCRIPT)

    toolchains = [
        "@rules_m4//m4:current_m4_toolchain",
        "@rules_flex//flex:current_flex_toolchain",
        "@rules_bison//bison:current_bison_toolchain",
        "@bsd_tar_toolchains//:resolved_toolchain",
        _PERL_TOOLCHAIN,
        _PYTHON_TOOLCHAIN,
    ]

    env = dict(
        BISON = "$(execpath @bison//bin:bison)",
        FLEX = "$(execpath @flex//bin:flex)",
        # The flex binary from rules_flex doesn't have a macro processor defined
        # at compile time so flex will try to find the m4 binary using the M4
        # env variable and if not set, it will just call `m4` and let `execvp`
        # to resolve it using `PATH`.
        M4 = "$(execpath @m4//bin:m4)",
        PYTHON = "$(execpath {})".format(_PYTHON_BIN),
        TAR = "$$EXT_BUILD_ROOT/$(BSDTAR_BIN)",
        # `PERL_SYSROOT_DIR`: absolute path of @perl_sysroot's per-arch root.
        # `$(execpath ...)` on `:perl` resolves to the perl binary at
        # `<sysroot>/usr/bin/perl`; three `dirname` calls climb to the
        # `<sysroot>` per-arch root. The underlying `perl_toolchain` instance
        # carries the broader @perl_sysroot tree as runfiles so the sibling
        # `usr/lib/<cpu>-linux-gnu/...` and `usr/share/perl/...` dirs
        # materialize alongside.
        PERL_SYSROOT_DIR = "$$(dirname $$(dirname $$(dirname $(execpath {bin}))))".format(
            bin = _PERL_BIN,
        ),
        # `PERL5LIB`: @perl_sysroot's perl can't find Config.pm via `@INC`
        # because Debian compiled it with HOST paths
        # (`/usr/lib/<cpu>-linux-gnu/perl/<version>`) that don't exist in the
        # hermetic sandbox. PERL5LIB points at the materialized tree's
        # perl-base, `perl/<version>`, and `share/perl/<version>` dirs. The
        # `Config_overrides.pm` shim dir comes first so `-MConfig_overrides`
        # (PERL5OPT, set in env_sysroot) loads it before Debian's actual
        # Config.pm.
        #
        # `$(PERL_MULTIARCH)` is the Debian multiarch tuple (e.g.
        # `x86_64-linux-gnu`) of the perl toolchain's OWN sysroot, emitted via
        # `TemplateVariableInfo` by `current_perl_toolchain` from the
        # `multiarch` attr threaded through `perl_toolchain(...)`. Under
        # standard toolchain resolution the perl interpreter is always picked
        # per the action's EXEC config, so `$(PERL_MULTIARCH)` reflects the exec
        # arch independently of the build's TARGET arch (which lives on the
        # per-PG sysroot and follows `@platforms//cpu`). Required for
        # cross-compile: a host-arch perl interpreter at exec time loading its
        # modules from its own multiarch lib dir while plperl links against a
        # different target-arch libperl from the per-PG sysroot.
        PERL5LIB = ":".join([
            "$$(dirname $(execpath {overrides}))".format(
                overrides = _PERL_CONFIG_OVERRIDES,
            ),
            "$$PERL_SYSROOT_DIR/usr/lib/$(PERL_MULTIARCH)/perl-base",
            "$$PERL_SYSROOT_DIR/usr/lib/$(PERL_MULTIARCH)/perl/" + _PERL_VERSION,
            "$$PERL_SYSROOT_DIR/usr/share/perl/" + _PERL_VERSION,
        ]),
    )

    # Sysroot env vars for meson dependency discovery. PKG_CONFIG_SYSROOT_DIR
    # prepends $SYSROOT_DIR to every path in `.pc` files. CFLAGS uses
    # `-idirafter` (not `C_INCLUDE_PATH`) so sysroot headers don't conflict with
    # system libc headers; perl-dev installs `perl.h` at
    # `usr/lib/<cpu>-linux-gnu/perl/<version>/CORE/`, so that path needs its own
    # entry (otherwise meson's plperl dep check fails with "missing perl.h"
    # because perl's `ExtUtils::Embed -e ccflags` reports the system path).
    env_sysroot = dict()

    if sysroot_tar:
        env_sysroot = dict(
            # The setup script extracts the tar, runs in-place sed on perl's
            # Config files, symlinks the @libc_sysroot clang wrapper inside the
            # extracted tree, and prints `$EXT_BUILD_ROOT/sysroot` (absolute).
            # `$(...)` captures it as SYSROOT_DIR; all downstream env vars
            # expand through it.
            SYSROOT_DIR = (
                "$$(sh $(execpath {setup}) $(execpath {tar}) " +
                "$(execpath {wrapper}) $(BSDTAR_BIN) {llvm_major})"
            ).format(
                setup = _SYSROOT_SETUP_SCRIPT,
                tar = sysroot_tar,
                wrapper = _SYSROOT_CLANG_WRAPPER,
                llvm_major = LLVM_MAJOR,
            ),
            PKG_CONFIG_SYSROOT_DIR = "$$SYSROOT_DIR",
            PKG_CONFIG_PATH = ":".join([
                "$$SYSROOT_DIR/usr/lib/$$(uname -m)-linux-gnu/pkgconfig",
                "$$SYSROOT_DIR/usr/share/pkgconfig",
            ]),
            CFLAGS = " ".join([
                "-idirafter $$SYSROOT_DIR/usr/include",
                "-idirafter $$SYSROOT_DIR/usr/include/$$(uname -m)-linux-gnu",
                "-idirafter $$SYSROOT_DIR/usr/lib/$$(uname -m)-linux-gnu/perl/" + _PERL_VERSION + "/CORE",
            ]),
            CXXFLAGS = " ".join([
                "-idirafter $$SYSROOT_DIR/usr/include",
                "-idirafter $$SYSROOT_DIR/usr/include/$$(uname -m)-linux-gnu",
                "-idirafter $$SYSROOT_DIR/usr/lib/$$(uname -m)-linux-gnu/perl/" + _PERL_VERSION + "/CORE",
            ]),
            LIBRARY_PATH = "$$SYSROOT_DIR/usr/lib/$$(uname -m)-linux-gnu",
            # Debian's multi-arch layout splits libs between `/lib/<arch>`
            # (libcrypt, libtinfo, libz) and `/usr/lib/<arch>` (libz3) — both
            # are needed in LD_LIBRARY_PATH because the hermetic Linux sandbox
            # has no host `/lib` fallback for runtime tool invocations (perl +
            # llvm-config + msgfmt).
            LD_LIBRARY_PATH = ":".join([
                "$$SYSROOT_DIR/usr/lib/$$(uname -m)-linux-gnu",
                "$$SYSROOT_DIR/usr/lib",
                "$$SYSROOT_DIR/lib/$$(uname -m)-linux-gnu",
                "$$SYSROOT_DIR/lib",
            ]),
            # `PERL5OPT` loads `Config_overrides.pm` (which `PERL5LIB` in `env`
            # makes available) so `ExtUtils::Embed::ldopts` emits `-L<per-PG
            # sysroot>/usr/lib/<cpu>-linux-gnu/perl/5.36/CORE -lperl`. Without
            # the shim, `archlibexp` would carry @perl_sysroot's reported HOST
            # path (which doesn't exist in the sandbox). `PERL_DEBIAN_ARCHLIB`
            # is the value the shim writes into `$Config{archlib}` /
            # `$Config{archlibexp}`. Both are conditional on `sysroot_tar`:
            # outside the per-PG sysroot scope there's no libperl-dev to link
            # against, so the shim has nothing to point at.
            PERL5OPT = "-MConfig_overrides",
            PERL_DEBIAN_ARCHLIB = "$$SYSROOT_DIR/usr/lib/$$(uname -m)-linux-gnu/perl/" + _PERL_VERSION,
        )

    # Build PATH with @perl_sysroot's `usr/bin` FIRST, so meson's
    # `find_program('perl')` resolves to the Debian perl-base 5.36 interpreter
    # from `@perl_sysroot` (ABI-locked with the per-PG sysroot's libperl-dev /
    # libperl5.36) rather than any other perl on PATH. Then python3 dir, then
    # (when sysroot) sysroot bin dirs. `usr/lib/llvm-14/bin` carries
    # `llvm-config-14` plus our action-time symlinked `clang` wrapper;
    # `find_program('clang')` resolves to the symlink, then meson canonicalizes
    # to the @libc_sysroot wrapper's persistent path when baking `CLANG` into
    # Makefile.global.
    path_components = [
        "$$PERL_SYSROOT_DIR/usr/bin",
        "$$(dirname $(execpath {}))".format(_PYTHON_BIN),
    ]

    if sysroot_tar:
        path_components.append("$$SYSROOT_DIR/usr/bin")
        path_components.append(
            "$$SYSROOT_DIR/usr/lib/llvm-" + LLVM_MAJOR + "/bin",
        )

    path_components.append("$$PATH")

    env_meson = dict(
        PATH = ":".join(path_components),
    )

    # Postgres configure-make build uses env variables to find / override tools
    # but the Meson build uses find_program(get_option('<TOOL>'), ...) so we
    # have to pass the tools as Meson options pointing them at the env
    # variables.
    meson_tool_options = dict(
        BISON = "$BISON",
        FLEX = "$FLEX",
        PYTHON = "$PYTHON",
        TAR = "$TAR",  # NOTE: PG meson 16.x marks `tar` REQUIRED
    )

    # env_sysroot must be merged first so SYSROOT_DIR is set before other
    # variables that reference it (PKG_CONFIG_SYSROOT_DIR, etc.)
    return dict(
        build_data = build_data,
        env = env_sysroot | env | env_meson,
        lib_source = pg_src,
        options = build_options | meson_tool_options,
        postfix_script = _STRIP_SANDBOX_PATHS_POSTFIX,
        target_args = {
            "setup": [
                "--auto-features=%s" % auto_features,
            ],
        },
        toolchains = toolchains,
        visibility = ["//visibility:public"],
    )

# After `make install`, Postgres's `lib/pgxs/src/Makefile.global` captures
# CFLAGS/LDFLAGS verbatim from the configure environment, which includes the
# toolchain's `--sysroot=<EXT_BUILD_ROOT>/external/.../sysroot` baked in by
# `llvm.sysroot(...)`, the action-time-extracted `$EXT_BUILD_ROOT/ sysroot/...`
# paths, plus various $EXT_BUILD_ROOT-relative tool paths (AR, BISON, ...). Once
# the postgres-install sandbox is torn down, all those paths point to a dead
# `/sandbox/linux-sandbox/<N>/execroot/_main/` prefix and downstream PGXS
# extension builds (e.g. citus 13.2.0/pg 16.0) fail to link.
#
# rules_foreign_cc has a built-in `replace_sandbox_paths` step that runs after
# `postfix_script`, but it only sed-replaces in files matching `*.pc`, `*.la`,
# `*-config`, `*.mk`, `*.cmake`. `Makefile.global` does not match any of those,
# so the framework's own rewrite skips it.
#
# Step 1 strips the sandbox prefix so absolute paths under sandbox execroots
# collapse to `/<install_base>/...` (persistent across sandbox teardowns via
# Bazel's install-base bind-mount).
#
# Step 2 rewrites the action-time `/sysroot/usr/lib/llvm-14/bin` prefix (where
# the tar-extracted Debian libllvm14 binaries lived during the action) to the
# persistent `@llvm_sysroot` bin dir (`/external/sysroots++sysroots+llvm_sysroot
# /debian/12/<arch>/usr/lib/llvm-14/bin`). Both paths point at the same Debian
# llvm-14 binaries (same APT_SNAPSHOT); the rewrite swaps the per-action sandbox
# location for the install-base-bind-mount-persistent one so PGXS extensions
# invoking `$(LLVM_BINPATH)/llvm-lto` succeed after sandbox teardown.
#
# Step 3 redirects just `/clang` (word-anchored) from `@llvm_sysroot`'s raw
# Debian clang to the @libc_sysroot `clang_wrapper.sh` shim. Postgres's runtime
# JIT path invokes `$(CLANG)` DIRECTLY to emit-llvm-IR; no cc_toolchain features
# inject `--sysroot=`, so the unwrapped clang would compile against host headers
# (no host in the hermetic sandbox; in the production container we want the
# deterministic Debian sysroot). The wrapper bakes `--sysroot=<libc_sysroot>`
# into every invocation. The `\\b` boundary keeps `clang-14`, `clang++`, etc.
# routed through `@llvm_sysroot` directly (they're only invoked by the build,
# not by runtime JIT).

# buildifier: disable=external-path
_STRIP_SANDBOX_PATHS_POSTFIX = """\
_arch=$$(uname -m | sed -e s/x86_64/amd64/ -e s/aarch64/arm64/)
find "$$INSTALLDIR" -name 'Makefile.global' -print0 \\
    | xargs -0 --no-run-if-empty \\
        sed -i -E \\
            -e 's|/sandbox/linux-sandbox/[0-9]+/execroot/[^/]+/|/|g' \\
            -e "s|/sysroot/usr/lib/llvm-{major}/bin|/external/sysroots++sysroots+llvm_sysroot/debian/12/$${{_arch}}/usr/lib/llvm-{major}/bin|g" \\
            -e "s|/external/sysroots[+][+]sysroots[+]llvm_sysroot/debian/12/$${{_arch}}/usr/lib/llvm-{major}/bin/clang\\b|/external/sysroots++sysroots+libc_sysroot/debian/12/$${{_arch}}/usr/lib/llvm-{major}/bin/clang|g"
""".format(major = LLVM_MAJOR)

def _pg_build_meson(name, pg_src, build_options, auto_features, sysroot_tar = None):
    pg_binaries = [
        "initdb",
        "postgres",
        "pg_config",
        "pg_isready",
    ]

    # these binaries are only built when contrib is enabled
    if build_options.get("contrib", "false") == "true":
        pg_binaries.extend([
            "vacuumlo",
            "oid2name",
        ])

    # including lib in out_data_dirs because even when it's out_lib_dir's
    # default, it's not included in declared_outputs
    out_data_dirs = [
        "lib",
        "share",
    ]

    meson_common_args = _meson_common_args(
        pg_src = pg_src,
        build_options = build_options,
        auto_features = auto_features,
        sysroot_tar = sysroot_tar,
    )

    meson(**(meson_common_args | dict(
        name = name,
        out_binaries = pg_binaries,
        out_data_dirs = out_data_dirs,
    )))

    # Debug target. On failure rules_foreign_cc prints the path to the
    # compilation log and the wrapper scripts but it can also be useful to
    # access these after a successful compilation (plus it gives a nicer path to
    # access the logs and a simple way to access it, just bazel build it).
    native.filegroup(
        name = "logs",
        srcs = [name],
        output_group = "Meson_logs",
    )

def _pg_build_introspect(name, pg_src, build_options, auto_features, sysroot_tar = None):
    meson_common_args = _meson_common_args(
        pg_src = pg_src,
        build_options = build_options,
        auto_features = auto_features,
        sysroot_tar = sysroot_tar,
    )

    meson(**(meson_common_args | dict(
        name = "introspect",
        out_include_dir = "",
        # Name the introspect JSON `tar.json` explicitly (the fixed name the
        # regen normalizer keys on, `_INTROSPECT_JSON_NAME`), not after the
        # build target `name`, so the normalizer always finds it.
        out_data_files = ["tar.json"],
        targets = ["introspect"],
        tags = ["manual"],
    )))

    native.filegroup(
        name = "introspect-logs",
        srcs = ["introspect"],
        output_group = "Meson_logs",
        tags = ["manual"],
    )

def pg_build(name, pg_src, build_options, auto_features, sysroot_tar = None):
    """
    Generates a Bazel target to build Postgres with the Meson build system.

    This rule configures the environment and invokes the rules_foreign_cc
    `meson` rule, using preconfigured options, toolchains, etc.

    Args:
        name (str): The name of the Bazel target to generate.
        pg_src (str): The external Bazel repo with the Postgres source code.
        build_options (dict): Meson build options that configure optional
            Postgres features and other compilation parameters.
        auto_features (str): Controls whether Meson build options and optional
            Postgres features not specified in `build_options` will be
            `enable`d, `disable`d or `auto` (enabled or disabled based on
            detected system capabilities).
        sysroot_tar (str): Optional `:sysroot_tar` alias label (rendered
            per-PG-version by `monoext/private/base/versions.bzl`, fed by the
            per-PG `@pgbuildtime_<key>//<distro>/<v>/<arch>:sysroot.tar`
            single-file artifact emitted by `//sysroots/apt`). At action time
            the tar is extracted to `$EXT_BUILD_ROOT/sysroot/`, exposed to meson
            via `SYSROOT_DIR`, `PKG_CONFIG_SYSROOT_DIR`, `CFLAGS`,
            `LD_LIBRARY_PATH`, etc. None disables sysroot wiring entirely
            (PG-source-only meson build).
    """

    _pg_build_meson(name, pg_src, build_options, auto_features, sysroot_tar)

    _pg_build_introspect(
        name,
        pg_src,
        build_options,
        auto_features,
        sysroot_tar,
    )

    pg_template_variable_info(
        name = "toolchain",
        target = name,
        visibility = ["//visibility:public"],
    )
