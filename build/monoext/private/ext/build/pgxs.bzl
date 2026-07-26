"""
Rules to build Postgres PGXS extensions from source.

Internal to monoext; invoked from generated `@{name}_ext//...` BUILD files. The
shared genrule scaffolding lives in `ext_build`; this file supplies the PGXS
`compile_extension` (autoconf `./configure` + `make` driven through `pgxs.mk`),
the prologue that stages the codegen tools, and the matching srcs / tools /
toolchains.
"""

load(
    "//monoext/private/ext/build:build.bzl",
    "ext_build",
)
load(
    "//monoext/private/ext/build:build_args.bzl",
    "PGXS_ARG_SUBST",
)
load("//toolchains/perl:perl_toolchain.bzl", _PERL_VERSION = "PERL_VERSION")

# Codegen tools for extensions whose Makefiles regenerate a scanner/parser at
# build time (e.g. Apache AGE: `ag_scanner.l` -> flex, `cypher_gram.y` ->
# bison). Postgres's installed `Makefile.global` bakes `FLEX`/`BISON` to the
# bazel exec-tool paths that only exist inside the PG build action's input tree,
# so an external extension that triggers the `.l`/`.y` rules cannot find them
# and dies with `flex: No such file or directory` (Error 127). Stage the same
# tools here and override `FLEX`/`BISON`/`M4` on the `make` command line (GNU
# make ranks command-line variables above the `Makefile.global` assignments).
# Mirrors the wiring in `monoext/private/base/pg_build.bzl`. The rules_flex flex
# has no built-in macro processor, so it resolves `m4` through the `M4` env var,
# which is exported below.
_M4 = "@m4//bin:m4"
_FLEX = "@flex//bin:flex"
_BISON = "@bison//bin:bison"

# Perl for extensions whose Makefiles run a `.pl` codegen script at build time
# (e.g. Apache AGE: `tools/gen_keywordlist.pl` -> `cypher_kwlist_d.h`). Same
# rationale as flex/bison: `Makefile.global` bakes `PERL` to the PG-build-only
# `@perl_sysroot` path. `_PERL_BIN` carries the `@perl_sysroot` tree as
# runfiles, so staging it and pointing `PERL5LIB` at that tree's core-module
# dirs lets the interpreter run a plain script. The plperl XS shim
# (`Config_overrides.pm` / `PERL5OPT`) that `pg_build.bzl` needs is
# intentionally omitted: external extensions run perl scripts, they do not link
# `libperl`. `$(PERL_MULTIARCH)` is emitted by `_PERL_TOOLCHAIN`.
_PERL_BIN = "@monogres//toolchains/perl:perl"
_PERL_TOOLCHAIN = "@monogres//toolchains/perl:current_perl_toolchain"

# Raw @perl_sysroot filegroup. Staged in `srcs` so the interpreter's core
# modules (`strict.pm`, `warnings.pm`, ...) are materialized at their source
# paths in the sandbox, where the `@perl_sysroot` perl's baked `@INC` (and the
# `PERL5LIB` derived below) look for them. `_PERL_BIN`'s runfiles alone are not
# co-located at those paths under a plain genrule (unlike rules_foreign_cc's
# `build_data`), so the tree must be an explicit action input.
_PERL_SYSROOT = "@monogres//toolchains/perl:sysroot"

# PGXS `compile_extension`: remap declared sysroot paths, copy the source tree,
# optionally run the shipped `./configure`, then `make` / `make install` through
# `pgxs.mk`. `make_pgxs_installdir` (defined by the shared engine) mirrors the
# DESTDIR tree.
_COMPILE_EXTENSION = """
        compile_extension() {{
            local cc="$$1"; shift
            local pgxs_src="$$1"; shift
            local sysroot_dir="$$1"; shift
            local pg_sysroot_dir="$$1"; shift
            local installdir="$$1"; shift

            # NOTE:
            # Unlike Meson, configure-make builds may write to the source tree.
            # While off-tree (VPATH) builds are theoretically supported, I haven't
            # found a reliable way to use it and still get all extension files
            # installed correctly into the pgxs_installdir (lib, share, etc).
            # To avoid this, we copy the pgxs_src tree and build from the copy.

            local pgxs_src_copy="$$EXT_BUILD_ROOT/pgxs_src_copy"

            # NOTE: -L because we need to copy the actual dir and not the symlink
            # NOTE: chmod because pgxs_src is a tree artifact (read-only in Bazel)
            cp -raL "$$pgxs_src" "$$pgxs_src_copy"
            chmod -R u+w "$$pgxs_src_copy"

            # NOTE:
            # Some autoconf-based extensions (citus) ship `configure` and
            # `configure.ac` in the source tarball with identical (or nearly
            # identical) timestamps. After `cp -raL` the sub-microsecond
            # mtime ordering can flip so configure.ac > configure, which
            # triggers the standard make rule
            #     configure: configure.ac
            #             ./autogen.sh
            # → `autoreconf -f`, which needs autoconf on the host. Touch
            # `configure` (if present) so make sees it as up-to-date and
            # skips regeneration. The shipped `configure` is what we want
            # to run anyway.
            if [[ -f "$$pgxs_src_copy/configure" ]]; then
                touch "$$pgxs_src_copy/configure"
            fi

            # Shared sysroot compile environment: sets the `target_multiarch`,
            # `cflags`, `ldflags` globals and exports PKG_CONFIG_SYSROOT_DIR /
            # PKG_CONFIG_PATH. See `setup_compile_env` in the shared engine.
            setup_compile_env "$$sysroot_dir" "$$pg_sysroot_dir"

            # `build_multiarch` is the Debian multiarch dirname for the BUILD
            # arch (where this action runs). Sourced from
            # `$(LIBC_SYSROOT_EXEC_MULTIARCH)`, the exec-config libc sysroot's
            # tuple (the exec arch is the build arch). Used to set autoconf's
            # `--build=` so cross-aware extension configure scripts know they
            # are not running on the target. Mirrors the shared engine's
            # `target_multiarch` on the exec side.
            local build_multiarch
            build_multiarch="$(LIBC_SYSROOT_EXEC_MULTIARCH)"

            # `@llvm_sysroot` lib dirs that hold llvm-lto's NEEDED libs
            # (libtinfo.so.6 in `lib/<multiarch>`, libLLVM-14.so.1 in
            # `usr/lib/llvm-14/lib`). pgxs.mk's install step invokes
            # `$$(LLVM_BINPATH)/llvm-lto` for ThinLTO bitcode indexing
            # under the canonical `@llvm_sysroot` path baked into
            # `Makefile.global` by `_STRIP_SANDBOX_PATHS_POSTFIX` in
            # `pg_build.bzl`. The sandbox chroot has no `/lib/<multiarch>`,
            # so the binary needs `LD_LIBRARY_PATH` pointing at its own
            # sysroot to find its NEEDED libs at exec time. The path is
            # surfaced via the `$(LLVM_SYSROOT_DIR)` make-variable bound by
            # the `//toolchains/llvm_sysroot:llvm_sysroot_dir` `sysroot_dir`
            # rule, so the canonical bzlmod repo name resolves at analysis
            # time without appearing in source.
            local llvm_sysroot
            llvm_sysroot="$$EXT_BUILD_ROOT/$(LLVM_SYSROOT_DIR)"

            # Link-time library search (`LIBRARY_PATH`) for the extension's own
            # `.so`: both TARGET sysroots' `<multiarch>` lib dirs. Distinct from
            # the broader `LD_LIBRARY_PATH` below, which also covers the
            # EXEC-arch build tools and the @llvm_sysroot ThinLTO libs.
            local library_path=(
              "$$sysroot_dir/usr/lib/$$target_multiarch"
              "$$pg_sysroot_dir/usr/lib/$$target_multiarch"
            )

            # @llvm_sysroot EXEC dirs, layered onto the shared EXEC group: they
            # carry `libLLVM-14.so.1` (and `libtinfo.so.6`) that the exec-arch
            # clang and `llvm-lto` NEED for the `-emit-llvm` bitcode path.
            # (`libc_sysroot_exec` / `exec_multiarch` and the shared EXEC /
            # TARGET groups come from `setup_compile_env`.)
            local llvm_sysroot_exec
            llvm_sysroot_exec="$$EXT_BUILD_ROOT/$(LLVM_SYSROOT_EXEC_DIR)"
            local ldpath_llvm_exec=(
              "$$llvm_sysroot_exec/lib/$$exec_multiarch"
              "$$llvm_sysroot_exec/usr/lib/$$exec_multiarch"
              "$$llvm_sysroot_exec/usr/lib/llvm-14/lib"
            )
            # @llvm_sysroot TARGET dirs: llvm-lto's NEEDED libs under the
            # canonical install-base-bind-mount path baked into Makefile.global.
            local ldpath_llvm_target=(
              "$$llvm_sysroot/lib/$$target_multiarch"
              "$$llvm_sysroot/usr/lib/llvm-14/lib"
            )
            # Runtime lib search: shared EXEC group, then the @llvm_sysroot exec
            # dirs, then the shared TARGET sysroots, then the llvm target dirs.
            local ld_library_path=(
              "$${{ldpath_exec[@]}}"
              "$${{ldpath_llvm_exec[@]}}"
              "$${{ldpath_target[@]}}"
              "$${{ldpath_llvm_target[@]}}"
            )

            # `LIBRARY_PATH` (link-time) and `LD_LIBRARY_PATH` (exec-time) layer
            # the same sysroots as the shared `PKG_CONFIG_PATH`, plus the pgxs
            # extras above (EXEC-arch tool libs, @llvm_sysroot ThinLTO libs).
            export LIBRARY_PATH
            LIBRARY_PATH="$$(IFS=:; echo "$${{library_path[*]}}")"
            export LD_LIBRARY_PATH
            LD_LIBRARY_PATH="$$(IFS=:; echo "$${{ld_library_path[*]}}")"

            # NOTE:
            # PGXS flag variables are exported as environment variables (not
            # passed on the make command line) so that extensions can freely
            # override or append to them in their Makefiles. In GNU Make,
            # command-line variables (priority 2) crush Makefile assignments
            # (priority 3), while environment variables (priority 4) act as
            # defaults. This lets the standard PGXS mechanism in pgxs.mk
            # (e.g. override CPPFLAGS := PG_CPPFLAGS + CPPFLAGS) merge
            # extension-defined flags with our sysroot flags correctly.
            export PG_CFLAGS="$${{cflags[*]}}"
            export PG_CPPFLAGS="$${{cflags[*]}}"
            export CPPFLAGS="$${{cflags[*]}}"
            export PG_LDFLAGS="$${{ldflags[*]}}"

            echo "# $$(date) - compile_extension"
            echo
            echo "pgxs_src: $$pgxs_src"
            echo "pgxs_src_copy: $$pgxs_src_copy"
            echo "PKG_CONFIG_SYSROOT_DIR: $$PKG_CONFIG_SYSROOT_DIR"
            echo "PKG_CONFIG_PATH: $$PKG_CONFIG_PATH"

            # PG-install-tree path overrides for `make` and `configure`.
            # PG's `lib/pgxs/src/Makefile.global` resolves every install
            # path (bindir, libdir, sharedir, ...) via
            # `$$(shell $$(PG_CONFIG) --<query>)` at make-include time, so
            # extension Makefiles inherit the relocated paths. Under
            # cross-compile `$$PG_CONFIG` is a target-arch binary that
            # cannot run on the build host; the `$$(shell ...)` calls
            # collapse to empty strings and PGXS rules then resolve
            # `<empty>/<file>` paths that link/install fail on.
            #
            # We compute the same paths from `$$abs_pg_install_dir` (the
            # absolute action-time install location, derived from the
            # `$(PG_INSTALL_DIR)` make-var, which is in turn derived from
            # `$(PG_CONFIG)`'s execpath under
            # `monoext/private/base/toolchain.bzl::_pg_other_template_vars`)
            # and pass them on the make command line. Command-line
            # overrides outrank the `:=` assignments in Makefile.global
            # (GNU make precedence), so the `$$(shell ...)` probes still
            # run but their results are discarded.
            local abs_pg_install_dir="$$EXT_BUILD_ROOT/$(PG_INSTALL_DIR)"
            local pg_path_overrides=(
                "bindir=$$abs_pg_install_dir/bin"
                "datadir=$$abs_pg_install_dir/share"
                "sysconfdir=$$abs_pg_install_dir/etc"
                "libdir=$$abs_pg_install_dir/lib"
                "pkglibdir=$$abs_pg_install_dir/lib"
                "includedir=$$abs_pg_install_dir/include"
                "pkgincludedir=$$abs_pg_install_dir/include"
                "mandir=$$abs_pg_install_dir/share/man"
                "docdir=$$abs_pg_install_dir/share/doc"
                "localedir=$$abs_pg_install_dir/share/locale"
                "PGXS=$$abs_pg_install_dir/lib/pgxs/src/makefiles/pgxs.mk"
            )

            if [ -f "$$pgxs_src_copy/configure" ]
            then
                echo
                echo "configure"
                echo

                # autoconf cross-compile signaling: `--host` is the GNU
                # triplet the binaries will RUN on (target arch), `--build`
                # is where this configure is RUNNING (build arch). When
                # they differ, autoconf sets `$$cross_compiling=yes`,
                # which gates AC_TRY_RUN / AC_CHECK_FILE / etc. on
                # non-executing fallbacks instead of running target-arch
                # binaries. Passing both unconditionally also works for
                # native builds (autoconf canonicalizes via config.sub
                # and just sets `$$cross_compiling=no`).
                local build_args=(
                    "--host=$$target_multiarch"
                    "--build=$$build_multiarch"
                    {build_args}
                )

                # `citusac_pg_config_version` bypasses Citus's
                # `$$($$PG_CONFIG --version)` probe in `configure`
                # (patched by `0002-13.2.0-cross-compile-skip-pg_config-
                # probe.patch` to honor this env var as an override).
                # The value mirrors what `pg_config --version` would emit
                # for the target PG build; Citus's `version_num`
                # extraction regex below the probe parses
                # `PostgreSQL X.Y...` shape. Set unconditionally because
                # the Makefile.global VERSION string is what `pg_config`
                # itself bakes into its `--version` output, so values
                # match by construction. Non-Citus extension configures
                # never read this variable and ignore it.
                local citus_pg_version
                citus_pg_version="$$(sed -n -E 's/^VERSION[[:space:]]*=[[:space:]]*//p' "$$abs_pg_install_dir/lib/pgxs/src/Makefile.global" | sed -n '1p')"

                # `ac_cv_file_<sanitized-path>` is autoconf's standard
                # cache-variable override for `AC_CHECK_FILE` results;
                # when set, autoconf reuses the cached value instead of
                # probing. `AC_CHECK_FILE` is documented as unsafe under
                # cross-compilation (autoconf bails with "cannot check
                # for file existence when cross compiling") because the
                # check runs on the build host, not the target.
                # Citus uses `AC_CHECK_FILE(.git, ...)` for `HAS_DOTGIT`
                # (used only by `Makefile.global.in`'s `GIT_VERSION`
                # stamping); pre-cache `=no` because the source tarball
                # has no `.git` directory and we don't want git-version
                # stamping anyway under sandbox/reproducible builds.
                # Setting `=no` is harmless for native builds (the
                # cached value just matches what the probe would find).
                # Other extensions that use AC_CHECK_FILE in the future
                # will need the same pre-cache treatment for the same
                # underlying autoconf limitation.

                # Subshell with `cd` instead of GNU `env -C`: busybox env
                # (what /usr/bin/env resolves to under the hermetic Linux
                # sandbox) doesn't support `-C`. The subshell form is pure
                # POSIX and works with both GNU env and busybox env.
                local configure_rc=0
                (
                    cd "$$pgxs_src_copy" && \
                    CC="$$cc" \
                    PG_CONFIG="$$EXT_BUILD_ROOT/$(PG_CONFIG)" \
                    CFLAGS="$${{cflags[*]}}" \
                    CPPFLAGS="$${{cflags[*]}}" \
                    LDFLAGS="$${{ldflags[*]}}" \
                    PG_CONFIG="$$EXT_BUILD_ROOT/$(PG_CONFIG)" \
                    citusac_pg_config_version="PostgreSQL $$citus_pg_version" \
                    ac_cv_file__git=no \
                    "$$pgxs_src_copy/configure" "$${{build_args[@]}}"
                ) || configure_rc=$$?

                if [ "$$configure_rc" -ne 0 ]; then
                    echo
                    echo "=== configure failed (rc=$$configure_rc); dumping config.log ==="
                    cat "$$pgxs_src_copy/config.log" 2>&1 || echo "(config.log unreadable)"
                    echo "=== end config.log ==="
                    return $$configure_rc
                fi
            fi

            echo
            echo "make"
            echo
            # CC/CXX/CPP + FLEX/BISON/M4/PERL: point make at real tools (the
            # defaults in Makefile.global reference PG-build-only paths).
            # pg_path_overrides relocate the PGXS install dirs (see above).
            # These must outrank the Makefile `:=` assignments, hence the
            # command line. CPPFLAGS: our sysroot include flags reach PGXS via
            # PG_CPPFLAGS, but an extension whose own Makefile assigns
            # PG_CPPFLAGS (e.g. Apache AGE's `-I src/include`) shadows that env
            # value, so the bitcode rule (raw clang using BITCODE_CFLAGS +
            # CPPFLAGS, not CFLAGS) loses --sysroot. A command-line CPPFLAGS
            # makes PGXS's `override CPPFLAGS` merge our sysroot flags back into
            # every rule, the .o and the .bc alike.
            local make_overrides=(
                CC="$$cc"
                CXX="$$cc"
                CPP="$$cc -E"
                FLEX="$$FLEX"
                BISON="$$BISON"
                M4="$$M4"
                PERL="$$PERL"
                CPPFLAGS="$${{cflags[*]}}"
                PG_CONFIG="$$EXT_BUILD_ROOT/$(PG_CONFIG)"
                "$${{pg_path_overrides[@]}}"
                USE_PGXS=1
            )

            "$$EXT_BUILD_ROOT/$(MAKE)" \
                -C "$$pgxs_src_copy" \
                "$${{make_overrides[@]}}" || return $$?

            echo
            echo "make install"
            echo
            "$$EXT_BUILD_ROOT/$(MAKE)" \
                -C "$$pgxs_src_copy" \
                "$${{make_overrides[@]}}" \
                DESTDIR="$$installdir" \
                install || return $$?

            echo
            echo "Extension compiled OK"
        }}
"""

# Prologue staging the codegen tools (flex / bison / m4 / perl) and the `cpp`
# shim label, spliced ahead of the sysroot setup so the compile can reference
# them.
_PROLOGUE_EXTRA = """
        # Codegen tools for extensions that regenerate a scanner/parser at build
        # time. Exported for make (and for flex, which resolves m4 via the M4 env
        # var); also passed as make command-line overrides below so they outrank
        # the PG-build-only paths baked into Makefile.global.
        FLEX="$$EXT_BUILD_ROOT/$(execpath {flex})"
        BISON="$$EXT_BUILD_ROOT/$(execpath {bison})"
        M4="$$EXT_BUILD_ROOT/$(execpath {m4})"
        export FLEX BISON M4

        # Perl for extensions whose Makefiles run a `.pl` codegen script. The perl
        # binary lives at `<perl_sysroot>/usr/bin/perl`; three dirnames climb to
        # the sysroot root. PERL5LIB points at the sysroot's core-module dirs
        # because the @perl_sysroot interpreter's baked @INC uses Debian host
        # paths absent from the sandbox.
        PERL="$$EXT_BUILD_ROOT/$(execpath {perl})"
        PERL_SYSROOT_DIR="$$(dirname $$(dirname $$(dirname "$$PERL")))"
        perl5lib=(
          "$$PERL_SYSROOT_DIR/usr/lib/$(PERL_MULTIARCH)/perl-base"
          "$$PERL_SYSROOT_DIR/usr/lib/$(PERL_MULTIARCH)/perl/{perl_version}"
          "$$PERL_SYSROOT_DIR/usr/share/perl/{perl_version}"
          "$$PERL_SYSROOT_DIR/usr/share/perl5"
        )
        PERL5LIB="$$(IFS=:; echo "$${{perl5lib[*]}}")"
        export PERL PERL5LIB
"""

def pgxs_build(
        name,
        src,
        deps_buildtime,
        base_version,
        base_hub,
        base_sysroot_tar,
        prefix_distro,
        build_args = [],
        debug = False):
    """Builds a PGXS extension with the [PGXS build system].

    [PGXS build system]: https://www.postgresql.org/docs/current/extend-pgxs.html

    Two buildtime sysroots are layered into the action: the per-extension
    sysroot (its own declared deps) is the primary `--sysroot=`, and the per-PG
    buildtime sysroot is layered via `-idirafter` / `-L` so headers and libs
    that Postgres's installed headers transitively require are reachable. This
    models the implicit assumption `pgxs.mk` makes on a Linux host (the host has
    every system package Postgres was built against). Extensions therefore
    declare only deps their own source code uses directly (the litmus test):
    anything inherited transitively from Postgres's interface comes in through
    the layered PG sysroot.

    Args:
        name (str): The name of the Bazel target to generate.
        src (str): The repo with the extension source code.
        deps_buildtime (list[str]): At most one entry, the per-target
            `@pg_ext//<name>/<v>/deps/buildtime:sysroot_tar` alias rendered by
            `monoext/private/ext/external.bzl`, resolving to the per-extension
            `@pgbuildtime_<key>//<distro>/<v>/<arch>:sysroot.tar` single-file
            artifact emitted by `//sysroots/apt`. Empty when the extension
            declares no buildtime deps (falls back to the @libc_sysroot tar via
            `@libc_sysroot//debian/12:sysroot_tar`; the layered PG sysroot still
            covers Postgres-interface deps).
        base_version (dict): `dict` with `name` and `version` keys to select the
            Postgres build that will be used when building the extension.
        base_hub (str): The base hub repo name (e.g. `"@pg"`). PG build targets
            and toolchains are resolved from this repo.
        base_sysroot_tar (str): Label of the per-PG buildtime sysroot tar
            (`@pg_ext//_base/<base_v>:sysroot_tar`), layered into the compile
            via `-idirafter` / `-L` so Postgres's interface deps are reachable
            without each extension re-declaring them.
        prefix_distro (str): The base prefix path for the distro install (e.g.
            `"/postgres"`, `"/ivorysql"`). The base version is appended
            internally.
        build_args (list[str]): Extra `./configure` flags from the extension's
            `metadata.build_args`, appended (templated to sysroot paths via
            `PGXS_ARG_SUBST`) when the source ships a `configure` script. Empty
            for PGXS extensions that declare none.
        debug (bool): If `True`, prints a debug message for each command
            executed.
    """
    ext_build(
        name = name,
        src = src,
        deps_buildtime = deps_buildtime,
        base_version = base_version,
        base_hub = base_hub,
        base_sysroot_tar = base_sysroot_tar,
        prefix_distro = prefix_distro,
        compile_extension = _COMPILE_EXTENSION,
        prologue_extra = _PROLOGUE_EXTRA,
        extra_srcs = [_PERL_SYSROOT],
        extra_tools = [_M4, _FLEX, _BISON, _PERL_BIN],
        extra_toolchains = [
            "@rules_m4//m4:current_m4_toolchain",
            "@rules_flex//flex:current_flex_toolchain",
            "@rules_bison//bison:current_bison_toolchain",
            _PERL_TOOLCHAIN,
        ],
        extra_format_kwargs = {
            "bison": _BISON,
            "flex": _FLEX,
            "m4": _M4,
            "perl": _PERL_BIN,
            "perl_version": _PERL_VERSION,
        },
        arg_subst = PGXS_ARG_SUBST,
        build_args = build_args,
        build_args_indent = 20,
        debug = debug,
    )
