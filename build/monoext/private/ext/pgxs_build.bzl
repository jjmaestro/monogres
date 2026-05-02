"""
Rules to build Postgres PGXS extensions from source.

Internal to monoext; invoked from generated `@{name}_ext//...` BUILD files.
"""

load("@platform_debian//:versions.bzl", "RELEASE")
load("//monoext/private/base/build_options:pg.bzl", "DEFAULT_PREFIX_DISTRO")
load("//toolchains/llvm_sysroot:llvm_version.bzl", "LLVM_MAJOR")

# Action-time setup script (shared with `pg_build.bzl`): extracts the per-PG
# sysroot tar into `$EXT_BUILD_ROOT/sysroot/`, sed-patches perl Config files in
# place, symlinks the @libc_sysroot clang wrapper inside the extracted tree, and
# prints the absolute sysroot path on stdout.
_SYSROOT_SETUP_SCRIPT = "@monogres//monoext/private/base:sysroot_setup.sh"

# Per-arch @libc_sysroot clang wrapper. Used for the action-time symlink dance
# so meson canonicalizes the symlink into the wrapper's persistent absolute path
# (under `/external/sysroots++sysroots+libc_sysroot/...`).
_SYSROOT_CLANG_WRAPPER = "@monogres//toolchains/libc_sysroot:active_clang_wrapper"

# Fallback buildtime sysroot tar (active Debian release) for extensions that
# declare no buildtime deps of their own; see the consumer below.
_LIBC_SYSROOT_TAR = "@libc_sysroot//debian/{}:sysroot_tar".format(
    RELEASE.version,
)

def pgxs_build(
        name,
        src,
        deps_buildtime,
        base_version,
        base_hub,
        base_sysroot_tar,
        prefix_distro = DEFAULT_PREFIX_DISTRO,
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
        prefix_distro (str): The base prefix path for the distro install
            (defaults to `DEFAULT_PREFIX_DISTRO`).
        debug (bool): If `True`, prints a debug message for each command
            executed.
    """

    # remove leading slash for use in relative paths within the tar
    prefix_distro_rel = prefix_distro.lstrip("/")

    tar_file, log_file = ["%s%s" % (name, file) for file in (".tar", ".log")]

    # Extensions without buildtime deps fall back to the @libc_sysroot tar
    # (codegen-emitted arch-selecting alias at
    # `@libc_sysroot//debian/12:sysroot_tar`). The setup script handles both
    # cases uniformly.
    sysroot_tar = deps_buildtime[0] if deps_buildtime else _LIBC_SYSROOT_TAR

    srcs = [
        # The SDK tree (`:tar.dev`): the full `meson install` carrying the
        # server headers + PGXS makefiles `pgxs.mk` compiles against. The
        # version-root `:tar.dev` alias resolves to the default option set's
        # SDK, matching the `:toolchain` (PG_CONFIG / PG_INSTALL_DIR) below.
        "%s//%s:tar.dev" % (base_hub, base_version["version"]),
        src,
        sysroot_tar,
        base_sysroot_tar,
        _SYSROOT_CLANG_WRAPPER,
        _SYSROOT_SETUP_SCRIPT,
    ]

    native.genrule(
        name = name,
        srcs = srcs,
        outs = [tar_file, log_file],
        cmd = """
        tar_() {{
            local tar_file="$$1"; shift
            local args=("$$@")

            local tar_cmd="{tar_cmd}"
            local tar_args=(
                {tar_args}
            )

            LC_ALL=C $$tar_cmd \
                -cf "$$tar_file" \
                "$${{tar_args[@]}}" \
                "$${{args[@]}}"
        }}

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

            local arch
            arch="$$(uname -m)"

            # NOTE:
            # Two sysroots layered: the extension's own (`sysroot_dir`,
            # searched first via `--sysroot=` + `-idirafter`) and the per-PG
            # buildtime sysroot (`pg_sysroot_dir`, layered via `-idirafter` /
            # `-L`). The extension sysroot ships the LLVM-toolchain compile-
            # time prerequisites (`LLVM_PREREQS` floor in
            # `monoext/private/pkgs.bzl`) AND every extension-specific
            # buildtime package; the PG sysroot covers everything
            # Postgres's installed headers transitively `#include` (libicu,
            # libssl, libxml2, etc., when Postgres was built with the
            # corresponding `--with-*` option). Extensions therefore declare
            # only deps their own source code uses directly.
            #
            # `--sysroot=<sysroot_dir>` is required for autoconf-style
            # extensions because their `./configure` invokes `$$CC conftest.c`
            # DIRECTLY (without going through bazel's cc_toolchain features
            # that would inject --sysroot via the cc_wrapper). Without this,
            # the conftest link dies looking for crt1.o / libgcc / libstdc++
            # from a nonexistent default sysroot. (Meson-based builds like
            # Postgres get --sysroot via cc_toolchain features and don't
            # need this manually.)
            local pg_cflags=(
                "--sysroot=$$sysroot_dir"
                "-idirafter $$sysroot_dir/usr/include"
                "-idirafter $$sysroot_dir/usr/include/$${{arch}}-linux-gnu"
                "-idirafter $$pg_sysroot_dir/usr/include"
                "-idirafter $$pg_sysroot_dir/usr/include/$${{arch}}-linux-gnu"
            )
            # NOTE:
            # `--sysroot` is duplicated here so configure's link-only checks
            # (which use LDFLAGS but not CFLAGS) find crt1.o et al.
            # `-Wl,--sysroot=` forwards sysroot to the linker so its
            # linker-script processing honors `=` sysroot-relative path
            # prefixes. The `@pgbuildtime_<key>` hub already rewrote Debian's
            # `lib*.so` linker scripts at repo-rule time (via //sysroots'
            # Tier-1 normalize) so absolute paths inside them are
            # `=`-prefixed. `-fuse-ld=lld` is not stated here because the
            # toolchain's cc_wrapper defaults link invocations to `lld` when
            # no `-fuse-ld=...` is otherwise specified.
            local pg_ldflags=(
                "--sysroot=$$sysroot_dir"
                "-Wl,--sysroot=$$sysroot_dir"
                "-L$$sysroot_dir/usr/lib/$${{arch}}-linux-gnu"
                "-L$$pg_sysroot_dir/usr/lib/$${{arch}}-linux-gnu"
            )

            local pkg_config_path=(
              "$$sysroot_dir/usr/lib/$${{arch}}-linux-gnu/pkgconfig"
              "$$sysroot_dir/usr/share/pkgconfig"
              "$$pg_sysroot_dir/usr/lib/$${{arch}}-linux-gnu/pkgconfig"
              "$$pg_sysroot_dir/usr/share/pkgconfig"
            )

            local library_path=(
              "$$sysroot_dir/usr/lib/$${{arch}}-linux-gnu"
              "$$pg_sysroot_dir/usr/lib/$${{arch}}-linux-gnu"
            )

            local ld_library_path=(
              "$$sysroot_dir/usr/lib/$${{arch}}-linux-gnu"
              "$$sysroot_dir/usr/lib"
              "$$pg_sysroot_dir/usr/lib/$${{arch}}-linux-gnu"
              "$$pg_sysroot_dir/usr/lib"
            )

            # NOTE:
            # `PKG_CONFIG_SYSROOT_DIR` can only point at one sysroot;
            # `.pc` files in extension deps (real per the litmus test)
            # live in the extension sysroot, so that's the one we set.
            # `PKG_CONFIG_PATH` lists both extension and PG `.pc`
            # directories so `pkg-config --libs` finds either. Same
            # layering for `LIBRARY_PATH` / `LD_LIBRARY_PATH`.
            export PKG_CONFIG_SYSROOT_DIR="$$sysroot_dir"
            export PKG_CONFIG_PATH
            PKG_CONFIG_PATH="$$(IFS=:; echo "$${{pkg_config_path[*]}}")"
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
            export PG_CFLAGS="$${{pg_cflags[*]}}"
            export PG_CPPFLAGS="$${{pg_cflags[*]}}"
            export CPPFLAGS="$${{pg_cflags[*]}}"
            export PG_LDFLAGS="$${{pg_ldflags[*]}}"

            echo "# $$(date) - compile_extension"
            echo
            echo "pgxs_src: $$pgxs_src"
            echo "pgxs_src_copy: $$pgxs_src_copy"
            echo "PKG_CONFIG_SYSROOT_DIR: $$PKG_CONFIG_SYSROOT_DIR"
            echo "PKG_CONFIG_PATH: $$PKG_CONFIG_PATH"

            if [ -f "$$pgxs_src_copy/configure" ]
            then
                echo
                echo "configure"
                echo
                env -C "$$pgxs_src_copy" \
                    CC="$$cc" \
                    PG_CONFIG="$$EXT_BUILD_ROOT/$(PG_CONFIG)" \
                    CFLAGS="$${{pg_cflags[*]}}" \
                    CPPFLAGS="$${{pg_cflags[*]}}" \
                    LDFLAGS="$${{pg_ldflags[*]}}" \
                    PG_CONFIG="$$EXT_BUILD_ROOT/$(PG_CONFIG)" \
                    "$$pgxs_src_copy/configure" || return $$?
            fi

            echo
            # PG install-tree path overrides for `make` / `make install`.
            # Postgres's `Makefile.global` resolves install dirs from
            # `$$($$PG_CONFIG --<query>)`, which reports PG's configure-time
            # `--prefix=` (the distro prefix) rather than the action-time
            # install location. Command-line overrides outrank the
            # `Makefile.global` `:=` assignments (GNU make precedence), so the
            # extension installs under `$$abs_pg_install_dir`, where the
            # relocate step below expects it.
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

            echo "make"
            echo
            local make_overrides=(
                CC="$$cc"
                CXX="$$cc"
                CPP="$$cc -E"
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

        make_pgxs_installdir() {{
            local installdir="$$1"; shift

            # The PGXS Makefile's `install` target writes to
            # `DESTDIR/<absolute install prefix>/{{lib,share,...}}` (the prefix
            # is baked into pg_config's `--bindir` / `--pkglibdir` / etc.
            # outputs by PG's configure-time `--prefix=`). To place the
            # extension tree under our action-writable `INSTALLDIR`, we
            # compute `<DESTDIR><absolute install prefix>` and pass it as
            # the per-action mirror of PG's install tree.
            #
            # The absolute install prefix is the action's CWD-relative
            # `$(PG_INSTALL_DIR)` make variable (set by the pg_template_
            # variable_info rule from `PG_CONFIG.split("/bin/pg_config")[0]`,
            # `monoext/private/base/toolchain.bzl::_pg_other_template_vars`)
            # prefixed with `$$EXT_BUILD_ROOT`.
            local abs_pg_install_dir="$$EXT_BUILD_ROOT/$(PG_INSTALL_DIR)"

            {{
                echo
                echo "installdir (DESTDIR): $$installdir"
                echo "abs_pg_install_dir: $$abs_pg_install_dir"
                echo "PG_INSTALL_DIR: $(PG_INSTALL_DIR)"
                echo
            }} >> "$$LOG_FILE"

            echo "$$installdir/$$abs_pg_install_dir"
        }}

        errors() {{
            {{
                echo
                echo
                echo "# $$(date)"
                echo
                echo

                env
            }} >> "$$LOG_FILE" 2>&1 || true

            # Dump the log to the saved-original stderr so bazel's
            # failed-action capture has the actual error. Bazel
            # unconditionally captures stderr even on action failure
            # and that capture survives sandbox teardown — unlike any
            # in-sandbox path, which is unreachable once the action
            # exits.
            #
            # CRITICAL: use fd 3 (saved stderr before the outer block's
            # `2>&1` redirect), NOT `>&2`. Inside the outer block, fd 2
            # points at LOG_FILE; `cat $$LOG_FILE >&2` would read LOG_FILE
            # and write back to LOG_FILE — infinite loop that grows the log
            # without bound (observed: 647 GB in ~18 min before disk filled
            # under hermetic sandbox).
            {{
                echo
                echo "========================================================"
                echo "  >> monoext action log ($$LOG_FILE) — action FAILED"
                echo "========================================================"
                echo
                cat "$$LOG_FILE" 2>/dev/null || echo "(LOG_FILE unreadable)"
                echo
                echo "========================================================"
                echo "  >> end of log (above)"
                echo "========================================================"
                echo
            }} >&3

            exit 1
        }}

        # Save the original stderr to fd 3 so the ERR trap can dump LOG_FILE
        # without recursing on the `2>&1` redirect inside the outer block.
        exec 3>&2

        trap errors ERR

        DEBUG="{debug}"
        [ "$$DEBUG" != True ] || set -x

        # =================================================================== #

        export EXT_BUILD_ROOT="$$PWD"

        TAR_FILE="$$EXT_BUILD_ROOT/{tar_file}"
        LOG_FILE="$$EXT_BUILD_ROOT/{log_file}"
        PGXS_SRC="$$EXT_BUILD_ROOT/{pgxs_src}"

        INSTALLDIR="$$EXT_BUILD_ROOT/$$(basename "$$TAR_FILE" .tar)"
        PGXS_INSTALLDIR="$$(make_pgxs_installdir "$$INSTALLDIR")"
        RELOCATED_PGXS_INSTALLDIR="$$EXT_BUILD_ROOT/relocated"

        CC="$$EXT_BUILD_ROOT/$(CC)"

        # Per-extension sysroot delivered as a single `:sysroot_tar` artifact
        # and extracted at action time by the shared setup script (also used
        # by `pg_build.bzl`). The script extracts to `$$EXT_BUILD_ROOT/sysroot/`,
        # sed-patches perl Config files in place, symlinks the @libc_sysroot
        # clang wrapper, and prints the absolute sysroot path on stdout. The
        # tar is unpacked by the hermetic `bsdtar` from `@bsd_tar_toolchains`,
        # the same family that wrote the archive at `sysroots/apt` repo-rule
        # time, so the pax snapshot round-trips end-to-end.
        SETUP_SH="$$EXT_BUILD_ROOT/$(execpath {setup})"
        SYSROOT_TAR_PATH="$$EXT_BUILD_ROOT/$(execpath {sysroot_tar})"
        WRAPPER_PATH="$$EXT_BUILD_ROOT/$(execpath {wrapper})"
        SYSROOT_DIR=$$(sh "$$SETUP_SH" "$$SYSROOT_TAR_PATH" "$$WRAPPER_PATH" "{tar_cmd}" "{llvm_major}")

        # Per-PG buildtime sysroot extracted inline with the same hermetic
        # `bsdtar`. No setup script needed: this tree is consumed read-only
        # for `-idirafter` / `-L` / pkg-config lookups (no perl patches, no
        # in-tree mutations).
        BASE_SYSROOT_TAR_PATH="$$EXT_BUILD_ROOT/$(execpath {base_sysroot_tar})"
        PG_SYSROOT_DIR="$$EXT_BUILD_ROOT/pg_sysroot"
        mkdir -p "$$PG_SYSROOT_DIR"
        {tar_cmd} -xf "$$BASE_SYSROOT_TAR_PATH" -C "$$PG_SYSROOT_DIR"

        export LOG_FILE

        {{
            compile_extension "$$CC" "$$PGXS_SRC" "$$SYSROOT_DIR" "$$PG_SYSROOT_DIR" "$$INSTALLDIR"
            mkdir -p "$$RELOCATED_PGXS_INSTALLDIR/{prefix_distro_rel}/{base_version}"
            mv -t "$$RELOCATED_PGXS_INSTALLDIR/{prefix_distro_rel}/{base_version}/." "$$PGXS_INSTALLDIR"/*
            tar_ "$$TAR_FILE" --directory "$$RELOCATED_PGXS_INSTALLDIR" .
        }} >> "$$LOG_FILE" 2>&1
        """.format(
            tar_cmd = "$(BSDTAR_BIN)",
            # NOTE: https://reproducible-builds.org/docs/archives/
            # We are using bsd tar which has less flags available. Consider
            # writing an mtree and/or find a way to use tar.bzl tar rule like we
            # did in extensions/contrib
            tar_args = "\n".join([
                "--format=posix",
                "--numeric-owner",
                "--owner=0",
                "--group=0",
            ]),
            tar_file = "$(locations %s)" % tar_file,
            log_file = "$(locations %s)" % log_file,
            prefix_distro_rel = prefix_distro_rel,
            base_version = base_version["version"],
            pgxs_src = "$(locations %s)" % src,
            setup = _SYSROOT_SETUP_SCRIPT,
            sysroot_tar = sysroot_tar,
            base_sysroot_tar = base_sysroot_tar,
            wrapper = _SYSROOT_CLANG_WRAPPER,
            llvm_major = LLVM_MAJOR,
            debug = "%s" % debug,
        ),
        target_compatible_with = select({
            # bsdtar.exe: -s is not supported by this version of bsdtar
            "@platforms//os:windows": ["@platforms//:incompatible"],
            "//conditions:default": [],
        }),
        toolchains = [
            "@bazel_tools//tools/cpp:current_cc_toolchain",
            "@bsd_tar_toolchains//:resolved_toolchain",
            "@rules_foreign_cc//toolchains:current_make_toolchain",
            "%s//%s:toolchain" % (base_hub, base_version["version"]),
        ],
        visibility = ["//visibility:public"],
    )
