"""
Shared engine for source-built Postgres extensions.

`ext_build` owns the single `native.genrule` that every extension build lowers
to: the reproducible-tar helper, the ERR trap that surfaces the action log, the
per-PG sysroot staging, the layered base-sysroot extraction, and the
DESTDIR-relocate epilogue that tars a `<base_v>.tar` under `<prefix_distro>`.

The per-build-system rules (`pgxs.bzl`, `cmake.bzl`) supply only what differs:
the `compile_extension` shell function that drives their toolchain, an optional
prologue that stages extra action-time tools, and the srcs / tools / toolchains
/ format values those pieces need. `ext_build` concatenates the shared and the
injected shell fragments into one template and runs a single `str.format` over
the whole, so a fragment's own `{{...}}` fields and `{{`/`}}` escapes resolve in
the same pass as the shared ones.
"""

load("@platform_debian//:versions.bzl", "RELEASE")
load("//monoext/private/ext/build:build_args.bzl", "render_build_args")
load("//toolchains/llvm_sysroot:llvm_version.bzl", "LLVM_MAJOR")

# Action-time setup script (shared with `pg_build.bzl`): extracts the per-PG
# sysroot tar into `$EXT_BUILD_ROOT/sysroot/`, sed-patches perl Config files in
# place, symlinks the @libc_sysroot clang wrapper inside the extracted tree, and
# prints the absolute sysroot path on stdout.
_SYSROOT_SETUP_SCRIPT = "@monogres//monoext/private/base:sysroot_setup.sh"

# sysroot_setup.sh sources this sibling lib (the shared extract / multiarch /
# chroot-symlink helpers) via `. $(dirname $0)/sysroot_lib.sh`, so it must ride
# the action inputs alongside the setup script; the two are co-located in the
# same package, so $0-relative resolution finds it once both are staged.
_SYSROOT_LIB_SCRIPT = "@monogres//monoext/private/base:sysroot_lib.sh"

# Per-arch @libc_sysroot clang wrapper. Used for the action-time symlink dance
# so meson canonicalizes the symlink into the wrapper's persistent absolute path
# (under `/external/sysroots++sysroots+libc_sysroot/...`).
_SYSROOT_CLANG_WRAPPER = "@monogres//toolchains/libc_sysroot:active_clang_wrapper"

# Test-introspect parser (opt-in via `emit_introspect`): turns an extension's
# own `make -n installcheck` dry run plus its `t/*.pl` / `*.control` globs into
# a committed-shaped `test_suites` JSON, so the catalog carries no transcribed
# test names. Staged into the action and invoked by the build system's
# `compile_extension` at the end of the build (where `pg_config` and the
# resolved make environment are in scope). Pure-Python stdlib run under the
# hermetic interpreter, exactly like the base make path's
# `pg_build_make_introspect.py`.
_EXT_INTROSPECT_SCRIPT = "@monogres//tools:ext_introspect.py"

# Hermetic Python interpreter for the introspect parser (the same one the base
# make path uses). `_PYTHON_FILES` is the full standalone install tree: the
# interpreter locates its stdlib relative to the binary, so it must materialize
# alongside `python3`. Both run on the exec machine, so they ride `tools`.
_EXT_INTROSPECT_PYTHON_BIN = "@python_3_11//:python3"
_EXT_INTROSPECT_PYTHON_FILES = "@python_3_11//:files"

# Fallback buildtime sysroot tar (active Debian release) for extensions that
# declare no buildtime deps of their own; see the consumer below.
_LIBC_SYSROOT_TAR = "@libc_sysroot//debian/{}:sysroot_tar".format(
    RELEASE.version,
)

# Per-arch @llvm_sysroot tree. Extensions that compile bitcode invoke
# `$(LLVM_BINPATH)/llvm-lto` (and friends) for ThinLTO indexing; the path lives
# under `external/<canonical_repo>/debian/12/<arch>/usr/lib/llvm-14/bin/` (baked
# into Postgres's installed `Makefile.global` by `_STRIP_SANDBOX_PATHS_POSTFIX`
# in `pg_build.bzl`). The label pulls the full LLVM tree into the action's
# hermetic input set so `llvm-lto`, its NEEDED `libLLVM-14.so.1`, and the rest
# of the LLVM-14 binaries resolve at install time. Arch-selecting alias is
# emitted by `//sysroots/common:codegen.bzl::version_root_build`.
_LLVM_SYSROOT = "@llvm_sysroot//debian/{}:sysroot".format(RELEASE.version)

# Toolchains every extension build needs, in the order the genrule resolves
# their make-variables. The per-build-system extras and the base-PG toolchain
# are appended by `ext_build`.
_SHARED_TOOLCHAINS = [
    "@bazel_tools//tools/cpp:current_cc_toolchain",
    "@bsd_tar_toolchains//:resolved_toolchain",
    "@monogres//toolchains/libc_sysroot:libc_sysroot_dir",
    "@monogres//toolchains/libc_sysroot:libc_sysroot_exec_dir",
    "@monogres//toolchains/llvm_sysroot:llvm_sysroot_dir",
    "@monogres//toolchains/llvm_sysroot:llvm_sysroot_exec_dir",
    "@rules_foreign_cc//toolchains:current_make_toolchain",
]

def ext_build(
        name,
        src,
        deps_buildtime,
        base_version,
        base_hub,
        base_sysroot_tar,
        prefix_distro,
        *,
        compile_extension,
        prologue_extra = "",
        extra_srcs = [],
        extra_tools = [],
        extra_toolchains = [],
        extra_format_kwargs = {},
        arg_subst = {},
        build_args = [],
        build_args_indent = 0,
        emit_introspect = False,
        debug = False):
    """Emits the extension-build genrule shared by every build system.

    The caller supplies the per-build-system shell fragments and wiring; this
    macro owns the shared scaffolding, the single `str.format`, and the genrule
    itself. `compile_extension` and `prologue_extra` are injected by
    concatenation (not as format values) so their own `{{field}}` placeholders
    and `{{`/`}}` escapes resolve in the same single format pass as the shared
    template's.

    Args:
        name (str): Bazel target name (the base version string).
        src (str): Label of the extension source tree, the source repo `:dir`.
        deps_buildtime (list[str]): At most one entry, the per-extension
            buildtime `:sysroot_tar` alias; empty falls back to `@libc_sysroot`.
        base_version (dict): `{{name, version}}` selecting the Postgres build.
        base_hub (str): Base hub repo (e.g. `"@pg"`).
        base_sysroot_tar (str): Per-PG buildtime sysroot tar
            (`//_base/<base_v>:sysroot_tar`), layered via `-idirafter`/`-L`.
        prefix_distro (str): Install prefix (e.g. `"/postgres"`); base version
            appended internally.
        compile_extension (str): Shell fragment defining `compile_extension`
            (and, for pgxs, its `make`-path helpers). Injected by concatenation.
        prologue_extra (str): Shell fragment staging extra action-time tools,
            spliced between the orchestration prologue and the sysroot setup.
        extra_srcs (list[str]): Build-system-specific genrule `srcs`.
        extra_tools (list[str]): Build-system-specific genrule `tools`.
        extra_toolchains (list[str]): Build-system-specific toolchains, resolved
            after the shared set and before the base-PG toolchain.
        extra_format_kwargs (dict): Additional `str.format` values the injected
            fragments reference (e.g. the pgxs codegen-tool labels).
        arg_subst (dict[str, str]): Portable-token -> action-time value map used
            to render `build_args`.
        build_args (list[str]): The extension's `metadata.build_args`.
        build_args_indent (int): Continuation indent for the rendered build
            args, matching the placeholder's column in `compile_extension`.
        emit_introspect (bool): If `True`, stage the test-introspect parser and
            emit a `<name>.tests.json` output; the build system's
            `compile_extension` runs `$EXT_INTROSPECT` at the end to discover
            the extension's own tests.
        debug (bool): If `True`, `set -x` the action.
    """
    prefix_distro_rel = prefix_distro.lstrip("/")
    tar_file, log_file = ["%s%s" % (name, file) for file in (".tar", ".log")]
    tests_json_file = "%s.tests.json" % name

    # Opt-in test-introspect wiring: the parser (a `srcs` entry) plus the
    # hermetic Python interpreter (exec-config `tools`), an extra `outs` entry
    # (the JSON), a prologue fragment exporting the interpreter + parser +
    # output paths, and the matching `str.format` values. All empty when the
    # build system does not emit an introspect.
    introspect_srcs = [_EXT_INTROSPECT_SCRIPT] if emit_introspect else []
    introspect_tools = [
        _EXT_INTROSPECT_PYTHON_BIN,
        _EXT_INTROSPECT_PYTHON_FILES,
    ] if emit_introspect else []
    introspect_outs = [tests_json_file] if emit_introspect else []
    introspect_env = """
        # Test-introspect parser + interpreter + output path, consumed by
        # `compile_extension`.
        EXT_INTROSPECT_PYTHON="$$EXT_BUILD_ROOT/$(execpath {ext_introspect_python})"
        EXT_INTROSPECT="$$EXT_BUILD_ROOT/$(execpath {ext_introspect})"
        INTROSPECT_OUT="$$EXT_BUILD_ROOT/{tests_json_out}"
        export EXT_INTROSPECT_PYTHON EXT_INTROSPECT INTROSPECT_OUT
        """ if emit_introspect else ""
    introspect_fmt = {
        "ext_introspect": _EXT_INTROSPECT_SCRIPT,
        "ext_introspect_python": _EXT_INTROSPECT_PYTHON_BIN,
        "tests_json_out": "$(locations %s)" % tests_json_file,
    } if emit_introspect else {}

    # Extensions without buildtime deps fall back to the @libc_sysroot tar
    # (codegen-emitted arch-selecting alias at
    # `@libc_sysroot//debian/12:sysroot_tar`). The setup script handles both
    # cases uniformly.
    sysroot_tar = deps_buildtime[0] if deps_buildtime else _LIBC_SYSROOT_TAR

    native.genrule(
        name = name,
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
            _LLVM_SYSROOT,
            _SYSROOT_SETUP_SCRIPT,
            _SYSROOT_LIB_SCRIPT,
        ] + introspect_srcs + extra_srcs,
        tools = introspect_tools + extra_tools,
        outs = [tar_file, log_file] + introspect_outs,
        # The shell script: shared scaffolding inline, with the per-build-system
        # `compile_extension` and `prologue_extra` fragments concatenated in
        # (never as `.format()` values, so their own `{{...}}` fields resolve in
        # the single pass below).
        cmd = "".join([
            """
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

        # Shared sysroot compile environment, identical for every build
        # system: the compiler is invoked directly here (autoconf's
        # `./configure`, CMake's compiler calls), bypassing the cc_toolchain
        # features that inject `--sysroot` for the meson-driven PG build, so
        # the sysroot flags must be set by hand. Two sysroots are layered: the
        # extension's own (`sysroot_dir`, primary `--sysroot=` + `-idirafter`)
        # and the per-PG buildtime sysroot (`pg_sysroot_dir`, `-idirafter` /
        # `-L`), so headers and libs Postgres's installed headers transitively
        # pull in resolve without each extension re-declaring them. Sets the
        # `target_multiarch`, `cflags`, `ldflags` globals for the caller to
        # consume its own way (pgxs via PG_CFLAGS / configure / make; cmake via
        # CMAKE_{{C,CXX}}_FLAGS) and exports the PKG_CONFIG_* env both use as
        # is. It also sets `exec_multiarch` and the shared `ldpath_exec` /
        # `ldpath_target` LD_LIBRARY_PATH groups; each `compile_extension`
        # composes its own LD_LIBRARY_PATH from them (pgxs interleaves its
        # @llvm_sysroot ThinLTO dirs) and sets LIBRARY_PATH itself, since the
        # two build systems' link-time search differs.
        setup_compile_env() {{
            local sysroot_dir="$$1"; shift
            local pg_sysroot_dir="$$1"; shift

            # `target_multiarch`: the Debian multiarch dirname for the TARGET
            # arch (e.g. `x86_64-linux-gnu`), from `$(LIBC_SYSROOT_MULTIARCH)`
            # (`toolchains` make-vars resolve in the genrule's TARGET config).
            # A pure arch fact, so it also names the sysroot lib/include dirs.
            target_multiarch="$(LIBC_SYSROOT_MULTIARCH)"

            # `--target=` picks clang's target arch (crt path, cross libgcc
            # lookup); `--sysroot=` roots the header / crt / lib search at the
            # extension sysroot; `-idirafter` layers both sysroots' includes
            # after the toolchain's own. For native builds `--target` is a
            # no-op (the EXEC and TARGET tuples match).
            cflags=(
                "--target=$$target_multiarch"
                "--sysroot=$$sysroot_dir"
                "-idirafter $$sysroot_dir/usr/include"
                "-idirafter $$sysroot_dir/usr/include/$$target_multiarch"
                "-idirafter $$pg_sysroot_dir/usr/include"
                "-idirafter $$pg_sysroot_dir/usr/include/$$target_multiarch"
            )
            # `--sysroot` is repeated on the link line so link-only checks
            # (LDFLAGS, not CFLAGS) still find crt1.o et al; `-Wl,--sysroot=`
            # forwards it to the linker so the `=`-prefixed paths in Debian's
            # rewritten `lib*.so` linker scripts resolve. `-fuse-ld=lld` is
            # implicit (the cc wrapper defaults link invocations to lld).
            ldflags=(
                "--target=$$target_multiarch"
                "--sysroot=$$sysroot_dir"
                "-Wl,--sysroot=$$sysroot_dir"
                "-L$$sysroot_dir/usr/lib/$$target_multiarch"
                "-L$$pg_sysroot_dir/usr/lib/$$target_multiarch"
            )

            # `.pc` search across both sysroots so `pkg-config` finds either
            # extension-declared or PG-interface deps.
            local pkg_config_path=(
                "$$sysroot_dir/usr/lib/$$target_multiarch/pkgconfig"
                "$$sysroot_dir/usr/share/pkgconfig"
                "$$pg_sysroot_dir/usr/lib/$$target_multiarch/pkgconfig"
                "$$pg_sysroot_dir/usr/share/pkgconfig"
            )

            # PKG_CONFIG_SYSROOT_DIR can name only one sysroot; the extension
            # sysroot holds the extension deps' `.pc` files, so it wins. Both
            # `.pc` dirs go on PKG_CONFIG_PATH.
            export PKG_CONFIG_SYSROOT_DIR="$$sysroot_dir"
            export PKG_CONFIG_PATH
            PKG_CONFIG_PATH="$$(IFS=:; echo "$${{pkg_config_path[*]}}")"

            # EXEC-arch sysroot dirs give build-machine tools (rules_foreign_cc's
            # `make`, clang) somewhere to find their NEEDED libs at action time;
            # the sandbox chroot has no host `/lib`. The EXEC-config make-vars
            # (`LIBC_SYSROOT_EXEC_DIR` / `LIBC_SYSROOT_EXEC_MULTIARCH`) resolve
            # regardless of the build's TARGET arch.
            # `usr/lib/<exec_multiarch>` carries `libffi.so.8` (Debian's
            # `libffi8`, transitive of `libllvm14`) which clang dynamic-loads for
            # the `-emit-llvm` bitcode path. `exec_multiarch` stays global so a
            # caller can layer more EXEC dirs onto it (pgxs adds @llvm_sysroot).
            exec_multiarch="$(LIBC_SYSROOT_EXEC_MULTIARCH)"
            local libc_sysroot_exec
            libc_sysroot_exec="$$EXT_BUILD_ROOT/$(LIBC_SYSROOT_EXEC_DIR)"

            # Shared LD_LIBRARY_PATH groups, composed into each build system's
            # final list (pgxs interleaves its @llvm_sysroot ThinLTO dirs between
            # them): the EXEC-arch build-tool libs, then the TARGET-arch libs
            # from the two layered sysroots (link-time `-L` fallback + runtime).
            ldpath_exec=(
              "$$libc_sysroot_exec/lib/$$exec_multiarch"
              "$$libc_sysroot_exec/usr/lib/$$exec_multiarch"
            )
            ldpath_target=(
              "$$sysroot_dir/usr/lib/$$target_multiarch"
              "$$sysroot_dir/usr/lib"
              "$$pg_sysroot_dir/usr/lib/$$target_multiarch"
              "$$pg_sysroot_dir/usr/lib"
            )
        }}
        """,
            compile_extension,
            """
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
            # prefixed with `$$EXT_BUILD_ROOT`. Computing this from the make
            # variable (vs. invoking `pg_config --bindir` at action time)
            # avoids running the TARGET-arch `pg_config` binary on the build
            # host under cross-compile, where it would fail with "Could not
            # open '/lib/ld-linux-<target_arch>.so.*'".
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
        PGXS_SRC="$$EXT_BUILD_ROOT/{src_loc}"

        INSTALLDIR="$$EXT_BUILD_ROOT/$$(basename "$$TAR_FILE" .tar)"
        PGXS_INSTALLDIR="$$(make_pgxs_installdir "$$INSTALLDIR")"
        RELOCATED_PGXS_INSTALLDIR="$$EXT_BUILD_ROOT/relocated"

        CC="$$EXT_BUILD_ROOT/$(CC)"
        """,
            introspect_env,
            prologue_extra,
            """
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
        """,
        ]).format(**(dict(
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
            src_loc = "$(locations %s)" % src,
            prefix_distro_rel = prefix_distro_rel,
            base_version = base_version["version"],
            setup = _SYSROOT_SETUP_SCRIPT,
            sysroot_tar = sysroot_tar,
            base_sysroot_tar = base_sysroot_tar,
            wrapper = _SYSROOT_CLANG_WRAPPER,
            llvm_major = LLVM_MAJOR,
            build_args = render_build_args(build_args, arg_subst, build_args_indent),
            debug = "%s" % debug,
        ) | extra_format_kwargs | introspect_fmt)),
        target_compatible_with = select({
            # bsdtar.exe: -s is not supported by this version of bsdtar
            "@platforms//os:windows": ["@platforms//:incompatible"],
            "//conditions:default": [],
        }),
        toolchains = _SHARED_TOOLCHAINS + extra_toolchains + [
            "%s//%s:toolchain" % (base_hub, base_version["version"]),
        ],
        visibility = ["//visibility:public"],
    )
