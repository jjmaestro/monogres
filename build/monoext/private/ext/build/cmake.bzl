"""
Rule to build CMake-based Postgres extensions (e.g. timescaledb, pgagent).

Internal to monoext; invoked from generated `@{name}_ext//...` BUILD files when
an extension declares `metadata.build_system == "cmake"`.

Reuses the shared genrule engine (`ext_build`): the same sysroot layering,
DESTDIR-relocate, and reproducible-tar scaffolding, with a CMake
`compile_extension` in place of the PGXS one. CMake itself is the prebuilt
binary from rules_foreign_cc's cmake toolchain (`$(CMAKE)` make-var via
`@rules_foreign_cc//toolchains:current_cmake_toolchain`), run through the Unix
Makefiles generator so the existing `$(MAKE)` toolchain drives the compile (no
ninja needed). The install runs with `DESTDIR` pointed at the action's capture
dir so CMake's absolute, `pg_config`-derived install paths land under it, then
the tree is relocated to `<prefix_distro>/<base_v>/` and tarred to `<name>.tar`,
matching the artifact contract the PGXS path produces.
"""

load(
    "//monoext/private/ext/build:build.bzl",
    "ext_build",
)
load(
    "//monoext/private/ext/build:build_args.bzl",
    "CMAKE_ARG_SUBST",
)
load("//toolchains/perl:perl_toolchain.bzl", _PERL_VERSION = "PERL_VERSION")

# rules_foreign_cc's prebuilt cmake, exposed for genrule use: the make-var
# `$(CMAKE)` (via `current_cmake_toolchain`'s TemplateVariableInfo) plus its
# file tree (its DefaultInfo, staged by listing the same label in `tools`).
_CMAKE_TOOLCHAIN = "@rules_foreign_cc//toolchains:current_cmake_toolchain"

# Perl for cmake extensions whose build runs a `.pl` codegen script (e.g.
# pgRouting generates `pgrouting--<ver>.sql` with `build-extension-file.pl`).
# The hermetic sandbox ships no perl core modules on the interpreter's baked
# `@INC`, so stage the `@perl_sysroot` tree and point `PERL5LIB` at its
# core-module dirs; mirrors the PGXS path's perl wiring. `$(PERL_MULTIARCH)` is
# emitted by `_PERL_TOOLCHAIN`.
_PERL_BIN = "@monogres//toolchains/perl:perl"
_PERL_TOOLCHAIN = "@monogres//toolchains/perl:current_perl_toolchain"

# Raw @perl_sysroot filegroup, staged in `srcs` so the interpreter's core
# modules materialize at their source paths in the sandbox (see the PGXS path).
_PERL_SYSROOT = "@monogres//toolchains/perl:sysroot"

# CMake `compile_extension`: take the shared sysroot compile environment
# (`setup_compile_env`, in the engine) and hand its `cflags` / `ldflags` to
# CMake via `-DCMAKE_{C,CXX}_FLAGS` (CMake invokes the compiler directly), then
# configure / build / install with `DESTDIR` pointed at the action capture dir.
_COMPILE_EXTENSION = """
        compile_extension() {{
            local cc="$$1"; shift
            local cmake_src="$$1"; shift
            local sysroot_dir="$$1"; shift
            local pg_sysroot_dir="$$1"; shift
            local installdir="$$1"; shift

            # Remap the declared baked paths in the sysroot's `*-config` scripts
            # so they resolve inside the extracted sysroot, for a build step that
            # reads a tool's raw output rather than going through the compiler's
            # sysroot search (e.g. an autoconf GDAL / libxml2 version check that
            # replaces CPPFLAGS/LIBS). Applied up front so the remapped sysroot
            # is in effect for the whole build. Empty (no calls) for extensions
            # that declare no `metadata.remap_paths`.
            {remap_paths}

            local abs_pg_install_dir="$$EXT_BUILD_ROOT/$(PG_INSTALL_DIR)"
            local cmake_bin="$$EXT_BUILD_ROOT/$(CMAKE)"
            local make_bin="$$EXT_BUILD_ROOT/$(MAKE)"
            local build_dir="$$EXT_BUILD_ROOT/cmake_build"

            # Shared sysroot compile environment: sets the `target_multiarch`,
            # `cflags`, `ldflags` globals and exports PKG_CONFIG_SYSROOT_DIR /
            # PKG_CONFIG_PATH. Handed to CMake via CMAKE_{{C,CXX}}_FLAGS below
            # since CMake invokes the compiler directly. See `setup_compile_env`
            # in the shared engine.
            setup_compile_env "$$sysroot_dir" "$$pg_sysroot_dir"

            # Runtime lib search from the shared groups (`setup_compile_env`);
            # CMake extensions need no @llvm_sysroot ThinLTO dirs.
            local ld_library_path=(
                "$${{ldpath_exec[@]}}"
                "$${{ldpath_target[@]}}"
            )

            export LIBRARY_PATH
            LIBRARY_PATH="$$(IFS=:; echo "$${{ld_library_path[*]}}")"
            export LD_LIBRARY_PATH
            LD_LIBRARY_PATH="$$(IFS=:; echo "$${{ld_library_path[*]}}")"

            echo "# $$(date) - cmake_build"
            echo "cmake_src: $$cmake_src"
            echo "cmake_bin: $$cmake_bin"
            echo "PKG_CONFIG_PATH: $$PKG_CONFIG_PATH"

            # Extension's own -D flags (templated), plus CMAKE_INSTALL_PREFIX
            # set to the PG install prefix so any prefix-relative install lands
            # in the PG tree; extensions that install to pg_config's absolute
            # paths honor DESTDIR below either way.
            local cmake_configure_args=(
                "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
                "-DCMAKE_C_COMPILER=$$cc"
                "-DCMAKE_CXX_COMPILER=$$cc"
                "-DCMAKE_C_FLAGS=$${{cflags[*]}}"
                "-DCMAKE_CXX_FLAGS=$${{cflags[*]}}"
                "-DCMAKE_EXE_LINKER_FLAGS=$${{ldflags[*]}}"
                "-DCMAKE_SHARED_LINKER_FLAGS=$${{ldflags[*]}}"
                "-DCMAKE_MODULE_LINKER_FLAGS=$${{ldflags[*]}}"
                "-DCMAKE_INSTALL_PREFIX=$$abs_pg_install_dir"
                "-DCMAKE_PREFIX_PATH=$$sysroot_dir/usr;$$pg_sysroot_dir/usr"
                "-DCMAKE_FIND_ROOT_PATH=$$sysroot_dir;$$pg_sysroot_dir"
                # C++ targets link via the clang wrapper's C driver, which
                # does not auto-add the C++ runtime. Append static libstdc++
                # at the end of the link line (from the LLVM_PREREQS
                # libstdc++-dev floor in the buildtime sysroot); inert for
                # C-only extensions.
                "-DCMAKE_CXX_STANDARD_LIBRARIES=-l:libstdc++.a"
                # Use the staged perl (with `PERL5LIB` set in the prologue) for
                # any `.pl` codegen the build runs; inert for extensions that
                # need no perl.
                "-DPERL_EXECUTABLE=$$PERL"
                {build_args}
            )

            echo
            echo "cmake configure"
            echo
            # PGDIR: FindPG.cmake (pgagent) discovers pg_config under $$PGDIR/bin.
            PGDIR="$$abs_pg_install_dir" \
            "$$cmake_bin" \
                -S "$$cmake_src" \
                -B "$$build_dir" \
                -G "Unix Makefiles" \
                -DCMAKE_MAKE_PROGRAM="$$make_bin" \
                "$${{cmake_configure_args[@]}}" || return $$?

            echo
            echo "cmake build"
            echo
            "$$cmake_bin" --build "$$build_dir" --parallel || return $$?

            echo
            echo "cmake install (DESTDIR=$$installdir)"
            echo
            DESTDIR="$$installdir" "$$cmake_bin" --install "$$build_dir" || return $$?

            echo
            echo "Extension compiled OK"
        }}
"""

# Prologue staging perl for cmake extensions with `.pl` codegen. `PERL5LIB`
# points at the `@perl_sysroot` core-module dirs since that interpreter's baked
# `@INC` uses Debian host paths absent from the sandbox; mirrors the PGXS path.
_PROLOGUE_EXTRA = """
        # Perl for cmake extensions whose build runs a `.pl` codegen script. The
        # perl binary lives at `<perl_sysroot>/usr/bin/perl`; three dirnames
        # climb to the sysroot root. `PERL5LIB` points at the sysroot's
        # core-module dirs. Passed to CMake as `-DPERL_EXECUTABLE` below.
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

def cmake_build(
        name,
        src,
        deps_buildtime,
        base_version,
        base_hub,
        base_sysroot_tar,
        prefix_distro,
        build_args = [],
        remap_paths = {},
        debug = False):
    """Builds a CMake-based Postgres extension.

    Args:
        name (str): Bazel target name (the base version string).
        src (str): Label of the extension source tree, the source repo `:dir`.
        deps_buildtime (list[str]): At most one entry, the per-extension
            buildtime `:sysroot_tar` alias; empty falls back to `@libc_sysroot`.
        base_version (dict): `{name, version}` selecting the Postgres build.
        base_hub (str): Base hub repo (e.g. `"@pg"`).
        base_sysroot_tar (str): Per-PG buildtime sysroot tar
            (`//_base/<base_v>:sysroot_tar`), layered via `-idirafter`/`-L`.
        prefix_distro (str): Install prefix (e.g. `"/postgres"`); base version
            appended internally.
        build_args (list[str]): Extra `-D` cache entries / flags from
            `metadata.build_args`, templated via `CMAKE_ARG_SUBST`
            (`{pg_config}` / `{sysroot}` / `{install_dir}`).
        remap_paths (dict[str, dict[str, str]]): `{file: {from: to}}` from
            `metadata.remap_paths`, applied to the sysroot's `usr/bin/<file>`
            scripts exactly as in the PGXS path (the dispatch splats one arg
            dict into either rule). No in-tree cmake extension declares it
            today.
        debug (bool): If `True`, `set -x` the action.
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
        extra_tools = [_CMAKE_TOOLCHAIN, _PERL_BIN],
        extra_toolchains = [_CMAKE_TOOLCHAIN, _PERL_TOOLCHAIN],
        extra_format_kwargs = {
            "perl": _PERL_BIN,
            "perl_version": _PERL_VERSION,
        },
        arg_subst = CMAKE_ARG_SUBST,
        build_args = build_args,
        build_args_indent = 16,
        remap_paths = remap_paths,
        remap_paths_indent = 12,
        debug = debug,
    )
