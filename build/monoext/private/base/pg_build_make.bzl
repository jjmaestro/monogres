"""
Rules to build PostgreSQL with the autoconf+make build system.

This module defines the `pg_build_make` macro, which drives `./configure && make
&& make install` against a PG source tree. It is a hand-rolled genrule rather
than a `rules_foreign_cc.configure_make` wrapper because the make-based PG
builds (PG <= 15.x via the version-keyed dispatch in
`flavors.bzl::FLAVORS["postgres"].build_system`) need a multi-step build
(writable source copy, post-configure `Makefile.global` edits, post-install
verification) and `configure_make` provides only `postfix_script` (after make),
not the pre-/mid-build hooks this path needs.

The macro mirrors the structure of `pg_build` (Meson): it consumes the same
per-PG `sysroot_tar` / `exec_sysroot_tar` pair, extracts them at action time via
the same `sysroot_setup.sh` / `exec_sysroot_setup.sh` scripts (which sed-patch
perl's Config files, plant the @libc_sysroot clang wrapper, and symlink the
sysroot's multiarch lib dirs into the chroot's standard ld.so search paths), and
emits a `:tar` artifact plus `:toolchain`, `:logs`, and `:introspect` (a
meson-shape introspect JSON synthesized from the install tree after `make
install`; the meson side gets the same data from a separate
`meson(targets=["introspect"])` run).

The Meson option vocabulary is shared with `pg_build`; this macro translates the
values to autoconf flags via
`build_options/configure_args.bzl::to_configure_args`. The `contrib` option is
not a `./configure` flag in autoconf — it controls the make target choice (`make
all` vs `make world-bin`); see `make_target_for` / `make_install_target_for` in
the same module.

Tool provenance (all hermetic, no host dependencies):

- The C compiler is the @libc_sysroot clang wrapper that `sysroot_setup.sh`
  plants at `$SYSROOT_DIR/usr/lib/llvm-<N>/bin/clang`. The wrapper self-
  discovers its sysroot via `readlink -f $0` and bakes `--sysroot=
  <libc_sysroot>` into every invocation — the same mechanism the Meson path
  bakes into `Makefile.global`'s `CLANG` for PGXS/JIT bitcode compilation. The
  Bazel cc_toolchain's `$(CC)` is NOT used: bare `$(CC)` invocations (which is
  all `./configure` can do) don't carry the toolchain's per-action `--sysroot`
  flag, so probe programs would compile against host headers that don't exist in
  the hermetic sandbox.
- make, bison, flex, m4, perl, pkg-config, msgfmt, llvm-config, clang++ all
  come from the per-PG sysroot (they are `deps.buildtime` Debian packages, so
  the apt snapshot pins them). rules_foreign_cc's bootstrapped GNU make cannot
  run inside the hermetic chroot (its bootstrap actions get no sysroot
  extraction, so its NEEDED libc never materializes at the chroot's multiarch
  paths), and the rules_bison / rules_flex toolchains need rules_foreign_cc
  wrapper machinery that a plain genrule doesn't have.
- Tools that RUN during the build resolve from `$EXEC_SYSROOT_DIR` (the
  EXEC-arch tree; for native builds `exec_sysroot_setup.sh` symlinks it to the
  target tree, so the paths are identical). Libs/headers the TARGET binaries
  compile and link against resolve from `$SYSROOT_DIR`.
- Python is the hermetic rules_python interpreter (same one the Meson path
  passes as `PYTHON`), with a `sitecustomize.py` shim fixing up
  python-build-standalone's `/install`-prefixed sysconfig vars.
- plpython's libpython probes are answered from the sysroot's Debian python
  (libpython3-dev is in every flavor's buildtime closure) through the
  sitecustomize shim; the driver interpreter only relays the facts.
"""

load("//monoext/private/base:toolchain.bzl", "pg_template_variable_info")
load(
    "//monoext/private/base/build_options:configure_args.bzl",
    "extra_libs_for",
    "make_install_target_for",
    "make_target_for",
    "to_configure_args",
)
load("//toolchains/llvm_sysroot:llvm_version.bzl", "LLVM_MAJOR")
load("//toolchains/perl:perl_toolchain.bzl", _PERL_VERSION = "PERL_VERSION")
load("//toolchains/python:python_toolchain.bzl", _PYTHON_VERSION = "PYTHON_VERSION")

# Perl interpreter from the @perl_sysroot toolchain, identical to `pg_build.bzl`
# (Meson): one perl toolchain across both build systems. `_PERL_BIN` is the
# per-arch alias to the Debian perl-base 5.36 interpreter; its `DefaultInfo` is
# the perl binary plus the full @perl_sysroot tree as runfiles (perl-base,
# perl/<V>, share/perl/<V>, and share/perl5 -- the last carrying IPC::Run for
# the `configure --enable-tap-tests` gate). The interpreter is ABI-reconciled
# with the per-PG sysroot's libperl-dev / libperl5.36 via the
# `Config_overrides.pm` shim (loaded through PERL5OPT), exactly as Meson does,
# so plperl links the per-PG libperl while everything runs on a single perl 5.36
# ABI track.
_PERL_BIN = "@monogres//toolchains/perl:perl"

# Full @perl_sysroot tree (arch-selecting alias). A native genrule's `tools`
# does not stage _PERL_BIN's runfiles the way Meson's `build_data` does, so the
# tree (perl-modules incl. ExtUtils::Embed, which autoconf's `ldopts` needs)
# must be a declared input in its own right.
_PERL_SYSROOT = "@monogres//toolchains/perl:sysroot"
_PERL_CONFIG_OVERRIDES = "@monogres//monoext/private/base:Config_overrides.pm"

# Action-time setup scripts shared with `pg_build` (Meson). See the docstrings
# in the scripts themselves; the contract here:
# - `sysroot_setup.sh <tar> <wrapper> <bsdtar> <llvm-major>` extracts the TARGET
# per-PG sysroot tar to `$EXT_BUILD_ROOT/sysroot`, sed-patches perl's
# `Config.pm` / `Config_heavy.pl` to sysroot-rooted paths, plants the
# @libc_sysroot clang wrapper at `usr/lib/llvm-<N>/bin/clang`, symlinks the
# sysroot's multiarch lib dirs into the chroot's `/lib/<arch>` +
# `/usr/lib/<arch>` (so sysroot ELFs and freshly-compiled `./conftest` binaries
# find their NEEDED libs through ld.so's default search), and prints the
# sysroot's absolute path.
# - `exec_sysroot_setup.sh <tar> <exec-tar> <bsdtar>` materializes the EXEC-arch
# tree at `$EXT_BUILD_ROOT/exec_sysroot` (a symlink to the target tree for
# native builds) and prints its absolute path. All arguments must be absolute:
# in genrule context `$(execpath ...)` is execroot-relative, so the build script
# prepends `$EXT_BUILD_ROOT/` itself (rules_foreign_cc does this implicitly for
# the Meson path).
_SYSROOT_LIB = "@monogres//monoext/private/base:sysroot_lib.sh"
_SYSROOT_SETUP_SCRIPT = "@monogres//monoext/private/base:sysroot_setup.sh"
_EXEC_SYSROOT_SETUP_SCRIPT = "@monogres//monoext/private/base:exec_sysroot_setup.sh"

# Per-arch @libc_sysroot clang wrapper, resolved in TARGET config so the
# select() inside picks the `--platforms` arch. Same label `pg_build` uses; see
# the rationale there (the wrapper file lives in a persistent external repo, so
# symlink canonicalization yields a path that survives sandbox teardown).
_SYSROOT_CLANG_WRAPPER = "@monogres//toolchains/libc_sysroot:active_clang_wrapper"

# Hermetic Python interpreter, used as `${PYTHON}` for `./configure` so PG's
# `config/python.m4` probes (`sysconfig.get_config_var('LIBDIR')` / `LIBPL`)
# return paths inside the bazel-managed Python install — paths that *exist*
# under the sandbox. The sysroot's Debian-packaged python bakes `/usr/lib/...`
# into its sysconfig data, which does not exist outside the sysroot extraction
# and would fail the libpython probe. Mirrors `pg_build.bzl`. `:files` is the
# full install tree (stdlib, headers, libpython); see the `tools` comment.
_PYTHON_BIN = "@python_3_11//:python3"
_PYTHON_FILES = "@python_3_11//:files"

# ---------------------------------------------------------------------------
# install_tree rule: extracts pg_build_make's tar output into a tree artifact
# that downstream consumers (`//utils:declare_outputs.bzl`) read via
# `OutputGroupInfo.gen_dir`. Mirrors the shape `rules_foreign_cc.meson` provides
# for its `:tar` target so the same contrib / extension-packaging code path
# works regardless of build system.
# ---------------------------------------------------------------------------

# Strip-components count for tar extraction. `pg_build_make`'s tar entries are
# shaped `./<distro>/<version>/<...>` (autoconf's `--prefix=/<distro>/
# <version>` baked into the install layout via `make install DESTDIR=...`). The
# three leading components to strip are `.`, `<distro>`, `<version>`, leaving
# `bin/`, `lib/`, `share/`, etc. at the install-dir root — the same no-prefix
# layout `rules_foreign_cc.meson` exposes.
_INSTALL_TREE_STRIP_COMPONENTS = 3

def _install_tree_impl(ctx):
    # Single-output strategy: the install root is one tree artifact under the
    # *target's own name* (`<target>/`), populated with `bin/`, `lib/`,
    # `include/`, `share/`. This matches `rules_foreign_cc.meson`'s layout
    # closely enough that `//utils:declare_outputs.bzl` (which reads
    # `OutputGroupInfo.gen_dir`) works unchanged, and — critically — `pg_config`
    # at runtime self-resolves its prefix from `$0/../..` to `<target>/`, so
    # `pg_config --pgxs` returns `<target>/lib/pgxs/...`, a path that actually
    # exists in PGXS extension sandboxes (it's the tree artifact Bazel
    # materializes for every consumer).
    #
    # We cannot also `declare_file("<target>/bin/<binary>")` because that path
    # overlaps the directory artifact. Instead we expose the binaries via a
    # `TemplateVariableInfo` provider built right here from the known binary
    # names — `pg_template_variable_info` forwards an existing provider instead
    # of scanning `DefaultInfo.files` (which for a tree artifact yields one File
    # for the whole directory, with no per-file paths visible at analysis time).
    install_dir = ctx.actions.declare_directory(ctx.label.name)

    # The hermetic sandbox has no `tar` (busybox mount manifest); use the
    # resolved bsdtar from `@bsd_tar_toolchains` — same binary family that wrote
    # the archive in the genrule, so the pax-format entries round-trip.
    bsdtar_info = ctx.attr._bsdtar[platform_common.TemplateVariableInfo]
    bsdtar_bin = bsdtar_info.variables["BSDTAR_BIN"]

    extract_cmd = (
        'rm -rf "{dst}"\n' +
        'mkdir -p "{dst}"\n' +
        '"{bsdtar}" -xf "{src}" --strip-components={strip} -C "{dst}"'
    ).format(
        bsdtar = bsdtar_bin,
        src = ctx.file.tar.path,
        strip = _INSTALL_TREE_STRIP_COMPONENTS,
        dst = install_dir.path,
    )
    ctx.actions.run_shell(
        inputs = depset(
            [ctx.file.tar],
            transitive = [ctx.attr._bsdtar[DefaultInfo].files],
        ),
        outputs = [install_dir],
        command = "set -euo pipefail\n" + extract_cmd,
        mnemonic = "PgInstallTreeExtract",
        progress_message = "Extracting PG install tree from %{input}",
    )

    # Template variables matching what `pg_template_variable_info` derives on
    # the Meson side. Paths are `<install_dir>/bin/<binary>`; each binary name
    # uppercases to a template variable (e.g. `pg_config` -> `PG_CONFIG`).
    # `PG_INSTALL_DIR` is the install root itself.
    template_vars = {
        b.upper().replace("-", "_"): "%s/bin/%s" % (install_dir.path, b)
        for b in ctx.attr.binaries
    }
    template_vars["PG_INSTALL_DIR"] = install_dir.path

    return [
        DefaultInfo(files = depset([install_dir])),
        OutputGroupInfo(gen_dir = depset([install_dir])),
        platform_common.TemplateVariableInfo(template_vars),
    ]

_install_tree = rule(
    implementation = _install_tree_impl,
    attrs = {
        "binaries": attr.string_list(
            mandatory = True,
            doc = (
                "PG binaries to expose as `TemplateVariableInfo` entries" +
                " (e.g. `pg_config` -> `PG_CONFIG=<install_dir>/bin/pg_config`)." +
                " Pass the same set the Meson path declares via `out_binaries`."
            ),
        ),
        "tar": attr.label(
            mandatory = True,
            allow_single_file = [".tar"],
            doc = "Genrule-produced tar file containing the install tree.",
        ),
        "_bsdtar": attr.label(
            default = "@bsd_tar_toolchains//:resolved_toolchain",
            doc = "Hermetic bsdtar used to extract the install tree.",
        ),
    },
    doc = """Adapter for pg_build_make's tar output.

Extracts the tar into a tree artifact at `<target>/` (with
`{bin,lib,include,share}/` directly inside, matching
`rules_foreign_cc.meson`'s layout). Exposes the install dir via
`OutputGroupInfo.gen_dir` for `//utils:declare_outputs.bzl`, and synthesizes
a `TemplateVariableInfo` with one entry per PG binary (plus
`PG_INSTALL_DIR`) — `pg_template_variable_info` forwards this if present, so
downstream `:toolchain` consumers see the same template vars they get on the
Meson path.""",
)

def _shell_array(values):
    """Render a Starlark list of strings as a bash array literal."""
    if not values:
        return ""
    return "\n".join(["                \"%s\"" % v for v in values])

def _pg_build_make_genrule(
        name,
        tar_file,
        log_file,
        introspect_json_file,
        pg_src,
        configure_args,
        extra_libs,
        make_targets,
        make_install_targets,
        extra_sources,
        sysroot_tar,
        exec_sysroot_tar,
        prefix,
        contrib_enabled,
        tap_tests_enabled,
        introspect_synth_script,
        antlr_cpp_runtime_srcs,
        antlr_jar,
        debug):
    srcs = [
        pg_src,
        # TARGET-config inputs: the per-PG sysroot tar (arch-select resolves to
        # the `--platforms` arch) and the matching clang wrapper. The exec tar
        # label is `exec_files`-wrapped at the version-root BUILD, so its inner
        # select() resolves in EXEC config even from this target-config attr.
        sysroot_tar,
        exec_sysroot_tar,
        _SYSROOT_CLANG_WRAPPER,
    ]

    # Each `extra_sources` entry contributes a source tree that gets merged into
    # the primary source tree at `contrib_dir` before `./configure` runs.
    # Rendered as bash array entries of the form
    # `<extra_path>::<contrib_dir>::<excludes_csv>` — the build script splits on
    # `::` to recover the three fields.
    extras_meta = []
    for _key, src in extra_sources.items():
        srcs.append(src["dir"])
        excludes_csv = ",".join(sorted(src.get("exclude", [])))
        extras_meta.append((src["dir"], src["contrib_dir"], excludes_csv))

    extras_array = "\n".join([
        '                "$(execpath %s)::%s::%s"' % (label, contrib_dir, excludes_csv)
        for (label, contrib_dir, excludes_csv) in extras_meta
    ])

    # ANTLR4 build-time inputs, unconditionally added on the make path so the
    # `prep_babelfishpg_tsql` shell step can find them. Make builds with no
    # `babelfishpg_tsql` overlay never run that step; they pay only the
    # label-resolution cost (two small filegroups, no transitive closures).
    srcs.append(antlr_cpp_runtime_srcs)
    srcs.append(antlr_jar)

    # `tools` (exec config) for everything that runs on the build machine.
    # `_PYTHON_FILES` is the full python-build-standalone install tree: the
    # interpreter locates its stdlib relative to `realpath(sys.executable)`, so
    # `lib/python3.X/` must materialize NEXT TO the binary as plain inputs (with
    # only the `:python3` binary staged, startup dies with `init_fs_encoding:
    # ... No module named 'encodings'`).
    #
    # `introspect_synth_script` walks the post-`make install` tree and the
    # source tree to produce a meson-shape introspect JSON consumable by Layer 2
    # + gen_contrib; it runs under the same hermetic interpreter.
    tools = [
        _SYSROOT_LIB,
        _SYSROOT_SETUP_SCRIPT,
        _EXEC_SYSROOT_SETUP_SCRIPT,
        _PYTHON_BIN,
        _PYTHON_FILES,
        introspect_synth_script,
        # Perl toolchain (exec config: the interpreter runs on the build
        # machine), mirroring the Meson path. `_PERL_BIN` gives the interpreter
        # ($(execpath) -> PERL_SYSROOT_DIR); `_PERL_SYSROOT` materializes the
        # full @perl_sysroot tree (perl-base, perl/<V>, share/perl/<V>,
        # share/perl5 incl. IPC::Run, and ExtUtils::Embed for autoconf's ldopts)
        # -- the native genrule does not stage _PERL_BIN's runfiles the way
        # Meson's `build_data` does, so the tree is a declared input.
        # `_PERL_CONFIG_OVERRIDES` is the %Config archlibexp/privlibexp shim.
        _PERL_BIN,
        _PERL_SYSROOT,
        _PERL_CONFIG_OVERRIDES,
    ]

    # `configure_args` rendered as a bash array.
    configure_args_array = _shell_array(configure_args)

    # Extra `-l<lib>` flags appended to `LIBS` in `Makefile.global` *after*
    # configure runs. Captures option-driven link additions like `-ldns_sd` for
    # bonjour that PG's autoconf does not add itself (see
    # `configure_args::extra_libs_for`). Joined into a single space-separated
    # token because that's what the sed replacement consumes.
    extra_libs_str = " ".join(extra_libs)

    # `make_targets` / `make_install_targets` are lists of `(subdir,
    # [target,...])` tuples — flatten to bash array entries of the form
    # `subdir|target1 target2 ...`. The build script splits on `|` and runs one
    # `make -C <subdir>` per entry.
    make_targets_array = _shell_array([
        "%s|%s" % (subdir, " ".join(targets))
        for (subdir, targets) in make_targets
    ])
    make_install_targets_array = _shell_array([
        "%s|%s" % (subdir, " ".join(targets))
        for (subdir, targets) in make_install_targets
    ])

    cmd_template = """
        set_up_sysroots() {{
            echo "# $$(date) - set_up_sysroots"

            # Both setup scripts consume $$EXT_BUILD_ROOT and print the
            # absolute path of the tree they materialize. The exec setup MUST
            # run after the target setup (its native fast-path symlinks
            # `exec_sysroot -> sysroot`, which the target setup just created).
            SYSROOT_DIR="$$(sh "$$SYSROOT_SETUP" \\
                "$$SYSROOT_TAR" "$$CLANG_WRAPPER" "$$BSDTAR" "$$LLVM_MAJOR")"
            EXEC_SYSROOT_DIR="$$(sh "$$EXEC_SYSROOT_SETUP" \\
                "$$SYSROOT_TAR" "$$EXEC_SYSROOT_TAR" "$$BSDTAR")"

            # Debian multiarch dirname for the TARGET arch, derived from the
            # sysroot tree (the apt resolver materializes exactly one
            # `<cpu>-linux-gnu/` dir for the build's target arch). NOT
            # `$$(uname -m)-linux-gnu`: that reports the HOST arch, which
            # breaks cross-compiled builds.
            TARGET_MULTIARCH="$$(ls "$$SYSROOT_DIR/usr/lib" \\
                | grep -E '^(x86_64|aarch64)-linux-gnu$$' | head -1)"

            # @perl_sysroot tree root: 3x dirname of the perl binary's execroot
            # path (.../usr/bin/perl -> .../usr/bin -> .../usr -> root). Same
            # interpreter + ABI-reconciliation the Meson path uses; see _PERL_BIN.
            PERL_SYSROOT_DIR="$$(dirname $$(dirname $$(dirname "$$EXT_BUILD_ROOT/{perl_bin}")))"

            # `prove` (from @perl_sysroot, found on PATH by `configure
            # --enable-tap-tests`) is a perl script with a `#!/usr/bin/perl`
            # shebang; the hermetic chroot has no /usr/bin/perl, so anything that
            # execs it by shebang fails ("not found", the missing interpreter).
            # Point /usr/bin/perl at the @perl_sysroot interpreter. Harmless for
            # non-TAP builds, which invoke perl via $$PERL. IPC::Run needs no
            # bridge: it rides @perl_sysroot's usr/share/perl5 on PERL5LIB (set
            # below), exactly as in pg_build.bzl.
            mkdir -p /usr/bin 2>/dev/null || true
            ln -sf "$$PERL_SYSROOT_DIR/usr/bin/perl" /usr/bin/perl

            export SYSROOT_DIR EXEC_SYSROOT_DIR TARGET_MULTIARCH PERL_SYSROOT_DIR
        }}

        # Helper: split an EXTRAS entry shaped
        # "<extra_path>::<contrib_dir>::<excludes_csv>" into the named global
        # vars `_E_PATH`, `_E_CDIR`, `_E_EXCL`. The third field may be empty
        # when no exclusions are declared.
        _parse_extras_entry() {{
            local entry="$$1"
            local rest
            _E_PATH="$${{entry%%::*}}"
            rest="$${{entry#*::}}"
            _E_CDIR="$${{rest%%::*}}"
            _E_EXCL="$${{rest#*::}}"
            if [ "$$_E_EXCL" = "$$_E_CDIR" ]; then
                # No third `::` separator -> no exclusions.
                _E_EXCL=""
            fi
        }}

        merge_extras() {{
            # The `<contrib_dir>` field names a directory that exists in
            # *both* the overlay and the workdir; for every immediate
            # subdirectory <X> under <extra_path>/<contrib_dir>/, copy
            # <extra_path>/<contrib_dir>/<X>/. into <workdir>/<contrib_dir>/
            # <X>/. so the subsequent configure/make sees a unified source
            # tree. The `*/` glob iterates only directories — top-level files
            # (Makefile, README.md, ...) at the overlay's <contrib_dir>/ are
            # intentionally skipped, since they would otherwise clobber the
            # primary tree's same-name file (most importantly the PG fork's
            # `contrib/Makefile`, which holds the SUBDIRS allowlist for PG's
            # standard contribs).
            #
            # Merge always copies ALL subdirs — the <excludes_csv> field is
            # consulted only by `pgxs_install_extras` (so excluded subdirs are
            # still present as source for peer contribs that #include their
            # headers).
            local workdir="$$1"; shift
            local extras=("$$@");

            echo "# $$(date) - merge_extras"

            for entry in "$${{extras[@]}}"; do
                _parse_extras_entry "$$entry"
                local src_root="$$EXT_BUILD_ROOT/$$_E_PATH/$$_E_CDIR"
                local dst_root="$$workdir/$$_E_CDIR"
                if [ ! -d "$$src_root" ]; then
                    echo "merge_extras: $$src_root is not a directory" >&2
                    return 1
                fi
                shopt -s nullglob
                local subdirs=("$$src_root"/*/)
                shopt -u nullglob
                # `-L` follows symlinks because the staged source tree may
                # carry symlinks back into the source repo.
                for src in "$${{subdirs[@]}}"; do
                    local name
                    name=$$(basename "$$src")
                    local dst="$$dst_root/$$name"
                    echo "  - $$src -> $$dst"
                    mkdir -p "$$dst"
                    cp -raL "$$src/." "$$dst/"
                done
            done
        }}

        build_antlr_runtime() {{
            # Compile antlr4-cpp-runtime to a static library from upstream
            # sources, NOT against the BCR `cc_library` artifact.
            #
            # The BCR `@antlr4-cpp-runtime` cc_library compiles with
            # `ANTLR4CPP_USING_ABSEIL` and links Abseil transitively — fine
            # for Bazel-built consumers, but unsuitable here: the resulting
            # symbols would end up inside `libbabelfishpg_tsql.so` (loaded
            # into a PG backend that mustn't depend on Abseil). Extracting
            # the upstream sources via `//utils:antlr4_cpp_runtime_srcs` (an
            # aspect-based rule walking the cc_library's
            # `srcs`/`hdrs`/`textual_hdrs`) and rebuilding them stock here
            # gives a clean, Abseil-free runtime.
            #
            # Outputs (under `$$out_dir`):
            #   include/antlr4-runtime/<headers...>
            #   lib/libantlr4-runtime.a
            #
            # The babelfish make-build links against this static lib, so the
            # resulting `babelfishpg_tsql.so` has no external
            # libantlr4-runtime runtime dep. The compiler is the sysroot's
            # clang++ pointed at the per-PG sysroot (libc + libstdc++ headers
            # live there), same as `run_configure`'s CXX.
            local antlr_src_dir="$$1"
            local out_dir="$$2"

            echo "# $$(date) - build_antlr_runtime"
            echo "  src: $$antlr_src_dir"
            echo "  out: $$out_dir"

            mkdir -p "$$out_dir/include/antlr4-runtime" "$$out_dir/lib"

            # Install headers: copy the entire runtime/src tree into
            # `include/antlr4-runtime/` so `#include "antlr4-runtime.h"` and
            # `#include "<sub>/<...>.h"` both resolve (matches upstream's
            # `/usr/local/include/antlr4-runtime/` layout).
            cp -aR "$$antlr_src_dir/runtime/src/." \\
                "$$out_dir/include/antlr4-runtime/"

            # Compile each .cpp to .o, then archive into libantlr4-runtime.a
            # (two-step because we want a static archive, not a shared
            # object).
            local cxx="$$SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/bin/clang++"
            local cxx_flags=(
                "--sysroot=$$SYSROOT_DIR"
                "-std=c++17" "-fPIC" "-O2" "-fvisibility=hidden"
                "-Wno-deprecated" "-Wno-attributes"
                "-I$$antlr_src_dir/runtime/src"
                "-idirafter" "$$SYSROOT_DIR/usr/include"
                "-idirafter" "$$SYSROOT_DIR/usr/include/$$TARGET_MULTIARCH"
            )

            local cpp_files=()
            while IFS= read -r f; do
                cpp_files+=("$$f")
            done < <(find "$$antlr_src_dir/runtime/src" -name "*.cpp")

            local objs_dir="$$out_dir/objs"
            mkdir -p "$$objs_dir"

            # Compile in parallel via xargs, mirroring the source tree's
            # directory structure under `$$objs_dir/` so basenames that
            # repeat across subdirs don't collide.
            printf '%s\\n' "$${{cpp_files[@]}}" | \\
                xargs -n 1 -P "$$JOBS" -I'@' bash -c '
                    src="@"
                    src_root="'"$$antlr_src_dir"'/runtime/src/"
                    rel="$${{src#$$src_root}}"
                    obj="'"$$objs_dir"'/$${{rel%.cpp}}.o"
                    mkdir -p "$$(dirname "$$obj")"
                    "'"$$cxx"'" '"$${{cxx_flags[*]}}"' -c "$$src" -o "$$obj"
                ' || return $$?

            # Archive all .o files into the static library (recursive find
            # because we mirror subdirs).
            local obj_list
            obj_list=$$(find "$$objs_dir" -name "*.o" -type f)
            # shellcheck disable=SC2086
            "$$EXEC_SYSROOT_DIR/usr/bin/ar" rcs \\
                "$$out_dir/lib/libantlr4-runtime.a" \\
                $$obj_list || return $$?

            rm -rf "$$objs_dir"
        }}

        prep_babelfishpg_tsql() {{
            # CMakeLists + Makefile + ANTLR-jar fixups for babelfishpg_tsql.
            #
            # The contrib's `Makefile` and `antlr/CMakeLists.txt` between
            # them hardcode several paths and version assumptions that need
            # patching for the sandboxed build:
            #
            #   Makefile (with `=` assignments — env-var override fails, and
            #   command-line make-vars don't compose with the Makefile's own
            #   `+=` because command-line vars become immutable):
            #     export ANTLR4_RUNTIME_INCLUDE_DIR=/usr/local/include/antlr4-runtime
            #     export ANTLR4_RUNTIME_LIB_DIR=/usr/local/lib
            #     export ANTLR4_JAVA_BIN=java
            #     (uses `$$(cmake)` — undefined -> empty -> cmake step no-ops)
            #     (no `-std=c++17` — antlr4-runtime 4.13.2 requires it)
            #
            #   CMakeLists.txt (no CACHE -> `-D` overrides ignored):
            #     SET (MYDIR /usr/local/include/antlr4-runtime/)
            #     set(CMAKE_CXX_STANDARD 14)
            #     set(ANTLR_EXECUTABLE
            #       $${{PROJECT_SOURCE_DIR}}/thirdparty/antlr/antlr-<v>.jar)
            #
            # Sed each path to point at the sysroot / our built runtime, and
            # bump C++14 -> C++17. The ANTLR jar referenced from
            # `ANTLR_EXECUTABLE` is left structurally alone — instead the
            # embedded jar file is overwritten in place with `@antlr_jar`
            # (version-matched to the runtime).
            local subdir="$$1"
            local antlr_runtime_dir="$$2"
            local antlr_jar="$$3"

            local java_bin
            java_bin=$$(find "$$EXEC_SYSROOT_DIR/usr/lib/jvm" \\
                -maxdepth 3 -name "java" -type f 2>/dev/null \\
                | head -1)
            if [ -z "$$java_bin" ]; then
                echo "prep_babelfishpg_tsql: java not found in $$EXEC_SYSROOT_DIR/usr/lib/jvm" >&2
                return 1
            fi

            # Patch the contrib's Makefile in-place:
            # - Hardcoded `/usr/local/{{include,lib}}` ANTLR paths -> our
            #   built runtime.
            # - `java` -> the sysroot's actual java binary (debs are
            #   extracted without running update-alternatives, so
            #   `/usr/bin/java` doesn't exist).
            # - Define `cmake := <sysroot cmake>` near the top so the
            #   existing `cd antlr && $$(cmake) .` step works.
            # - `PG_CXXFLAGS += -std=c++17` (antlr4-runtime 4.13.2 needs it).
            # - `PG_CFLAGS += -fcommon`: allows the multiple tentative
            #   definitions babelfish carries
            #   (`pltsql_curr_compile_body_lineno` lives in both
            #   `src/pl_comp.c` and `src/pl_comp-2.c`; `pgtsql_base_yydebug`
            #   in both `gram-backend.c` and `parser.c`). GCC 10+ and modern
            #   clang default to `-fno-common`, which turns these into
            #   linker errors.
            # The Makefile internals are modified (not command-line vars)
            # because the Makefile uses `PG_CFLAGS += ...` for its own
            # additions, and command-line vars can't be appended to from
            # within the Makefile.
            local makefile="$$subdir/Makefile"
            sed -i \\
                -e "s|^export ANTLR4_RUNTIME_INCLUDE_DIR=.*|export ANTLR4_RUNTIME_INCLUDE_DIR=$$antlr_runtime_dir/include/antlr4-runtime|" \\
                -e "s|^export ANTLR4_RUNTIME_LIB_DIR=.*|export ANTLR4_RUNTIME_LIB_DIR=$$antlr_runtime_dir/lib|" \\
                -e "s|^export ANTLR4_JAVA_BIN=.*|export ANTLR4_JAVA_BIN=$$java_bin|" \\
                -e "1icmake := $$EXEC_SYSROOT_DIR/usr/bin/cmake" \\
                -e "1iPG_CXXFLAGS += -std=c++17" \\
                -e "1iPG_CFLAGS += -fcommon" \\
                "$$makefile"

            # The JIT bitcode step (`%.bc : %.cpp` in `Makefile.global`)
            # uses `BITCODE_CXXFLAGS + CPPFLAGS`; PG_CXXFLAGS doesn't reach
            # it. `-std=c++17` and the runtime include dir are needed for
            # the bitcode-side .cpp compiles. Injected via `override
            # BITCODE_CXXFLAGS += ...` appended after `include $$(PGXS)`
            # so the additions land on top.
            #
            # Single-quoted `echo` strings keep `$$(...)` literal — those
            # lines end up in the Makefile and are interpreted by make, not
            # bash. The double-quoted form is for the line that needs
            # `$$antlr_runtime_dir` expanded by bash.
            echo "" >> "$$makefile"
            echo "# Injected by monoext/pg_build_make (BCR antlr4-cpp-runtime 4.13.2)." \\
                >> "$$makefile"
            echo "override BITCODE_CXXFLAGS += -std=c++17 -I$$antlr_runtime_dir/include/antlr4-runtime" \\
                >> "$$makefile"
            # Move `antlr/libantlr_tsql.a` from `OBJS` to `SHLIB_LINK`.
            # PGXS's JIT-bitcode install macro (`install_llvm_module` in
            # `Makefile.global`) does `$$(patsubst %.o,%.bc, $$(OBJS))` and
            # feeds the result to `llvm-lto --thinlto`. `.a` entries don't
            # match the patsubst and stay literal, so the archive ends up
            # in the lto input list and fails with "not a valid object
            # file". Moving the .a out of OBJS keeps it in the .so link
            # (via SHLIB_LINK) while excluding it from the bitcode
            # iteration. Done as a Make-level filter override rather than
            # a sed against the line itself to stay robust against every
            # variant the babelfish Makefile may use to add the archive.
            echo 'override OBJS := $$(filter-out %.a,$$(OBJS))' \\
                >> "$$makefile"
            echo 'SHLIB_LINK += antlr/libantlr_tsql.a' \\
                >> "$$makefile"

            # Patch the contrib's CMakeLists:
            # 1. Repoint `/usr/local/include/antlr4-runtime` to our built
            #    runtime's include dir.
            # 2. Bump `CMAKE_CXX_STANDARD` 14 -> 17: the antlr4-cpp-runtime
            #    4.13.2 headers use C++17 features (std::string_view,
            #    std::any, ...). Babelfish trees that set 14 targeted the
            #    older 4.9-era runtime; jar + runtime are pinned to 4.13.2
            #    here, so C++17 is required.
            local cmakelists="$$subdir/antlr/CMakeLists.txt"
            if [ -f "$$cmakelists" ]; then
                sed -i \\
                    -e "s|/usr/local/include/antlr4-runtime/|$$antlr_runtime_dir/include/antlr4-runtime/|g" \\
                    -e "s|CMAKE_CXX_STANDARD 14|CMAKE_CXX_STANDARD 17|g" \\
                    "$$cmakelists"
            fi

            # Overwrite the embedded ANTLR jar with `@antlr_jar` (same
            # filename, version-matched to the runtime). The CMakeLists
            # hardcodes the embedded jar's filename — that path keeps
            # working because only the file contents are replaced.
            shopt -s nullglob
            local embedded_jars=("$$subdir/antlr/thirdparty/antlr"/antlr-*-complete.jar)
            shopt -u nullglob
            if [ "$${{#embedded_jars[@]}}" -ge 1 ]; then
                cp -f "$$antlr_jar" "$${{embedded_jars[0]}}"
            fi

            # Per-version source compat. Babelfish trees written against
            # the ANTLR 4.9-era API call helpers that 4.13.2 removed.
            # Detect the legacy usage by grepping `tsqlIface.cpp` for
            # `antlrcpp::utf8_to_utf32` (the canonical legacy call); the
            # grep is the version selector, no separate version arg needed.
            local iface="$$subdir/src/tsqlIface.cpp"
            if [ -f "$$iface" ] && grep -q "antlrcpp::utf8_to_utf32" "$$iface"; then
                echo "    detected legacy ANTLR API in babelfishpg_tsql; applying compat patches"
                apply_legacy_antlr_compat_patches "$$iface"
            fi
        }}

        apply_legacy_antlr_compat_patches() {{
            # Migrate the three ANTLR 4.9-era call sites in `tsqlIface.cpp`
            # to the 4.13 equivalents:
            #
            #   antlrcpp::utf8_to_utf32(begin, end) -> antlrcpp::Utf8::lenientDecode(string_view)
            #   antlrcpp::utf32_to_utf8(u32string)  -> antlrcpp::Utf8::lenientEncode(u32string_view)
            #   UTF32String                         -> std::u32string
            #
            # `antlrcpp::Utf8` lives in `support/Utf8.h`, which is NOT in
            # the umbrella `antlr4-runtime.h`; add the explicit include
            # right after it so the call sites compile.
            local iface="$$1"
            sed -i \\
                -e "s|antlrcpp::utf8_to_utf32(s, s + strlen(s))|antlrcpp::Utf8::lenientDecode(std::string_view(s, strlen(s)))|g" \\
                -e "s|UTF32String\\b|std::u32string|g" \\
                -e "s|antlrcpp::utf32_to_utf8(rewritten_query)|antlrcpp::Utf8::lenientEncode(std::u32string_view(rewritten_query))|g" \\
                '-e' '/^#include "antlr4-runtime.h"/a\\
#include "support/Utf8.h"' \\
                "$$iface"
        }}

        pgxs_install_extras() {{
            # Post-install PGXS pass for overlay contribs (auto-discovered).
            # The PG fork installs first via `make install[-world-bin]`, then
            # each PGXS-shaped overlay extension is built+installed against
            # the just-staged `pg_config` via `USE_PGXS=1`. PG's core
            # `contrib/Makefile` has a hardcoded SUBDIRS list and does not
            # recurse into overlay-added subdirs, so they must be installed
            # in this separate pass.
            #
            # Strict-by-default: a per-subdir failure fails the whole build.
            # If a specific overlay contrib needs build-env pieces not
            # plumbed through this pass, list it in the catalog's
            # `metadata.extra_sources.<key>.exclude` array so this pass skips
            # it explicitly. `babelfishpg_tsql` is handled inline below
            # (ANTLR4 cmake codegen wiring): `prep_babelfishpg_tsql` patches
            # the contrib's Makefile + CMakeLists; the runtime itself is
            # compiled once by `build_antlr_runtime` and reused.
            #
            # Skips a subdir silently when it has no Makefile (defensive —
            # every PGXS-shaped contrib has one, but an overlay may ship
            # non-installable helper directories).
            local workdir="$$1"; shift
            local installdir="$$1"; shift
            local prefix="$$1"; shift
            local extras=("$$@");

            echo "# $$(date) - pgxs_install_extras"

            local pg_config="$$installdir$$prefix/bin/pg_config"
            if [ ! -x "$$pg_config" ]; then
                echo "pgxs_install_extras: pg_config not found at $$pg_config" >&2
                return 1
            fi

            # Build the antlr4 runtime once, lazily — only when a contrib in
            # the extras list actually needs it. Checks the *unfiltered*
            # subdir list (excludes don't matter at the gate level).
            local antlr_runtime_dir="$$EXT_BUILD_ROOT/antlr_runtime"
            local need_antlr=0
            for entry in "$${{extras[@]}}"; do
                _parse_extras_entry "$$entry"
                if [ -d "$$EXT_BUILD_ROOT/$$_E_PATH/$$_E_CDIR/babelfishpg_tsql" ]; then
                    need_antlr=1
                    break
                fi
            done
            if [ "$$need_antlr" = "1" ]; then
                build_antlr_runtime "$$ANTLR_CPP_SRC_DIR" "$$antlr_runtime_dir" \\
                    || return $$?
            fi

            for entry in "$${{extras[@]}}"; do
                _parse_extras_entry "$$entry"
                local src_root="$$EXT_BUILD_ROOT/$$_E_PATH/$$_E_CDIR"
                local excludes_csv="$$_E_EXCL"
                shopt -s nullglob
                local subdirs=("$$src_root"/*/)
                shopt -u nullglob
                for src in "$${{subdirs[@]}}"; do
                    local name
                    name=$$(basename "$$src")
                    # Skip if `name` is in the comma-separated exclude list.
                    # `,$$excludes_csv,` framing lets the substring search
                    # match the first and last entries unambiguously.
                    if [ -n "$$excludes_csv" ] \\
                        && [[ ",$$excludes_csv," == *",$$name,"* ]]; then
                        echo "  - skip $$name (excluded via metadata.extra_sources)"
                        continue
                    fi
                    local subdir="$$workdir/$$_E_CDIR/$$name"
                    if [ ! -f "$$subdir/Makefile" ]; then
                        echo "  - skip $$subdir (no Makefile)"
                        continue
                    fi
                    echo "  - PGXS install: $$subdir"

                    # Per-contrib pre-install hooks. Currently one case:
                    # babelfishpg_tsql needs ANTLR4 build-env plumbing
                    # (cmake codegen + linked runtime). The hook patches
                    # the contrib's Makefile + CMakeLists in place.
                    #
                    # `local_jobs` lets per-contrib hooks downgrade the
                    # parallelism when the contrib's Makefile races under
                    # `make -j`. babelfishpg_tsql's Makefile is missing the
                    # dependency edge from `src/tsqlIface.o` to the
                    # cmake-generated parser headers, so the outer make is
                    # serialized; the cmake/codegen pre-step is internally
                    # parallel and keeps `-j$$JOBS`.
                    local local_jobs="$$JOBS"
                    case "$$name" in
                        babelfishpg_tsql)
                            prep_babelfishpg_tsql "$$subdir" \\
                                "$$antlr_runtime_dir" "$$ANTLR_JAR_PATH" \\
                                || return $$?
                            local_jobs="1"
                            echo "    pre-step: build antlr/libantlr_tsql.a"
                            "$$MAKE_BIN" \\
                                -C "$$subdir" \\
                                -j"$$JOBS" \\
                                USE_PGXS=1 \\
                                PG_CONFIG="$$pg_config" \\
                                PG_SRC="$$workdir" \\
                                antlr/libantlr_tsql.a || return $$?
                            ;;
                    esac

                    # PG_SRC points at the merged PG source tree so the
                    # overlay's PGXS Makefiles can resolve `-I$$(PG_SRC)`
                    # includes against PG-internal headers.
                    #
                    # Note: no `DESTDIR` is passed. PGXS resolves install
                    # paths via `pg_config --libdir` / `--sharedir` / etc.,
                    # which at runtime use argv[0]-relative computation — so
                    # the staged pg_config (at
                    # $$installdir$$prefix/bin/pg_config) reports paths that
                    # already include $$installdir as their prefix. Adding
                    # DESTDIR=$$installdir would double-prefix the
                    # destinations and the install would land outside the
                    # expected staging subtree.
                    # shellcheck disable=SC2086
                    "$$MAKE_BIN" \\
                        -C "$$subdir" \\
                        -j"$$local_jobs" \\
                        FLEXFLAGS=-noline \\
                        USE_PGXS=1 \\
                        PG_CONFIG="$$pg_config" \\
                        PG_SRC="$$workdir" \\
                        install || return $$?
                done
            done
        }}

        set_up_build_env() {{
            echo "# $$(date) - set_up_build_env"

            # Tools that RUN during configure/make resolve from the EXEC tree
            # (native builds: identical to the target tree). The llvm bin dirs
            # carry llvm-config plus the planted clang wrapper; `find`-style
            # probes with no env-var override (msgfmt for nls, tclsh for tcl,
            # pkg-config) resolve via PATH.
            # @perl_sysroot's usr/bin FIRST so `perl` / `prove` resolve to the
            # perl toolchain (ABI-locked with the per-PG libperl-dev), mirroring
            # pg_build.bzl's PATH ordering. Then the EXEC per-PG sysroot bins.
            local path=(
                "$$PERL_SYSROOT_DIR/usr/bin"
                "$$EXEC_SYSROOT_DIR/usr/bin"
                "$$EXEC_SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/bin"
                "$$SYSROOT_DIR/usr/bin"
                "$$SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/bin"
            )
            export PATH="$$(IFS=:; echo "$${{path[*]}}"):$$PATH"

            # The sysroot ELFs (make, bison, perl, llvm-config, clang++, ...)
            # mostly resolve their NEEDED libs through the chroot-standard
            # `/lib/<arch>` + `/usr/lib/<arch>` symlinks `sysroot_setup.sh`
            # plants; LD_LIBRARY_PATH covers the rest (read-only chroot paths
            # where the symlink plant is best-effort, and the llvm-14 private
            # lib dir which is not under a multiarch root).
            local ld_library_path=(
                "$$EXEC_SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH"
                "$$EXEC_SYSROOT_DIR/lib/$$TARGET_MULTIARCH"
                "$$EXEC_SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/lib"
                "$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH"
                "$$SYSROOT_DIR/lib/$$TARGET_MULTIARCH"
                "$$SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/lib"
                "$$SYSROOT_DIR/usr/lib"
            )
            export LD_LIBRARY_PATH="$$(IFS=:; echo "$${{ld_library_path[*]}}")"

            # pkg-config from the sysroot (Debian 12 ships it via `pkgconf`,
            # which usually provides the `pkg-config` name; fall back to the
            # `pkgconf` binary if the compat name is absent). The sysroot-dir
            # override makes `.pc`-reported `-I/usr/include/...` /
            # `-L/usr/lib/...` paths resolve inside the extracted tree.
            PKG_CONFIG="$$EXEC_SYSROOT_DIR/usr/bin/pkg-config"
            [ -x "$$PKG_CONFIG" ] || PKG_CONFIG="$$EXEC_SYSROOT_DIR/usr/bin/pkgconf"
            export PKG_CONFIG
            export PKG_CONFIG_SYSROOT_DIR="$$SYSROOT_DIR"
            local pkg_config_path=(
                "$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/pkgconfig"
                "$$SYSROOT_DIR/usr/share/pkgconfig"
                "$$SYSROOT_DIR/usr/lib/pkgconfig"
            )
            export PKG_CONFIG_PATH="$$(IFS=:; echo "$${{pkg_config_path[*]}}")"

            # bison/flex/m4 from the sysroot. The BISON_PKGDATADIR / M4 env
            # vars are how Debian's bison finds its m4sugar data and the m4
            # binary outside its compiled-in /usr/share path; exported so the
            # make-time bison/flex invocations inherit them too.
            export BISON="$$EXEC_SYSROOT_DIR/usr/bin/bison"
            export BISON_PKGDATADIR="$$EXEC_SYSROOT_DIR/usr/share/bison"
            export FLEX="$$EXEC_SYSROOT_DIR/usr/bin/flex"
            export M4="$$EXEC_SYSROOT_DIR/usr/bin/m4"

            # Perl from the @perl_sysroot toolchain (PERL_SYSROOT_DIR), identical
            # to pg_build.bzl: one perl across both build systems. PERL5LIB lists
            # the Config_overrides.pm dir first, then @perl_sysroot's module dirs
            # under the sysroot multiarch, then the vendor `usr/share/perl5`
            # carrying IPC::Run for the `configure --enable-tap-tests` gate.
            # PERL5OPT loads the shim so plperl's `ExtUtils::Embed::ldopts` emits
            # `-L<per-PG sysroot>/usr/lib/<target-arch>/perl/<V>/CORE -lperl`
            # (PERL_DEBIAN_ARCHLIB) instead of @perl_sysroot's compiled-in HOST
            # path; the per-PG libperl-dev / libperl5.36 keep the plperl lifecycle
            # on a single perl 5.36 ABI.
            export PERL="$$PERL_SYSROOT_DIR/usr/bin/perl"
            local perl5lib=(
                "$$(dirname "$$EXT_BUILD_ROOT/{perl_config_overrides}")"
                "$$PERL_SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/perl-base"
                "$$PERL_SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/perl/$$PERL_VERSION"
                "$$PERL_SYSROOT_DIR/usr/share/perl/$$PERL_VERSION"
                "$$PERL_SYSROOT_DIR/usr/share/perl5"
            )
            export PERL5LIB="$$(IFS=:; echo "$${{perl5lib[*]}}")"
            export PERL5OPT="-MConfig_overrides"
            export PERL_DEBIAN_ARCHLIB="$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/perl/$$PERL_VERSION"

            # tcl from the sysroot. The exec `tclsh`'s compiled-in TCL_LIBRARY is
            # the host path `/usr/share/tcltk/tcl8.6`, absent in the sandbox, so
            # without an override tclsh cannot find `init.tcl` and configure's
            # `--with-tcl` probe ("checking for tclConfig.sh") fails before the
            # interpreter even initializes. Point TCL_LIBRARY at the EXEC
            # sysroot's tcl script library (Debian installs `init.tcl` + the
            # `tcl8/` module dir, incl. msgcat, here) so tclsh initializes and
            # configure resolves tclConfig.sh (`usr/lib/tcl8.6/`). The runtime
            # harness sets the same var against the runtime closure for pltcl.
            export TCL_LIBRARY="$$EXEC_SYSROOT_DIR/usr/share/tcltk/tcl8.6"

            # GNU make from the sysroot (see module docstring: RFCC's
            # bootstrapped make cannot run inside the hermetic chroot).
            MAKE_BIN="$$EXEC_SYSROOT_DIR/usr/bin/make"

            # Parallelism: the hermetic chroot has no `nproc` (busybox mount
            # manifest), but /proc is always mounted.
            JOBS="$$(grep -c ^processor /proc/cpuinfo)"
        }}

        set_up_python_shim() {{
            # python-build-standalone (the upstream of rules_python's hermetic
            # interpreter) bakes a `/install` sentinel into sysconfig's
            # build-time variables — `LIBDIR=/install/lib`,
            # `LIBPL=/install/lib/python3.X/config-...`,
            # `INCLUDEPY=/install/include/python3.X`. These were meant to be
            # rewritten when the interpreter is "installed" to a final
            # location, but rules_python uses the interpreter in-place
            # (`sys.prefix` is computed dynamically from `sys.executable`,
            # but the static config vars aren't re-written automatically).
            #
            # PG's autoconf plpython detection reads these static vars
            # verbatim — `python.m4` runs the equivalent of
            # `$${{PYTHON}} -c "import sysconfig; print(...LIBDIR)"` and
            # then checks for `libpython3.X.so` under that path, which
            # fails when `LIBDIR` resolves to `/install/lib`.
            #
            # The fix: drop a `sitecustomize.py` on `PYTHONPATH` that
            # monkey-patches `sysconfig._CONFIG_VARS` at startup, replacing
            # `/install` with the real prefix derived from `sys.executable`.
            # `site.py` imports `sitecustomize` automatically before user
            # code runs, so every `$${{PYTHON}} -c "..."` invocation from
            # configure picks this up transparently.
            # Target-python block (the second block below): PG's `python.m4`
            # discovers libpython link/include facts by querying the RUNNING
            # python's `sysconfig` (LIBDIR, LDLIBRARY, LIBPL, INCLUDEPY,
            # LDVERSION; PG 15's python.m4 is pure-sysconfig). That
            # interpreter is the rules_python build driver and is not what
            # plpython links; the facts the build needs describe the
            # sysroot's Debian python. When `PG_PYTHON_TARGET_SYSROOT`,
            # `PG_PYTHON_TARGET_MULTIARCH` and `PG_PYTHON_TARGET_VERSION` are
            # exported (see `run_configure`), the shim rewrites the
            # embed-relevant vars to that sysroot's Debian python paths
            # (libpython3-dev ships the headers, the `libpython3.X.so` dev
            # symlink at the multiarch root, and the `config-3.X-<ma>/` LIBPL
            # dir). The target version comes from the release profile, so the
            # build driver and the target python need not match. The shim
            # leaves the vars untouched (and warns) when the target include
            # dir is absent, so configure's libpython check fails fast instead
            # of silently linking the driver interpreter's own libpython.
            local shim_dir="$$1"
            mkdir -p "$$shim_dir"
            cat > "$$shim_dir/sitecustomize.py" << 'PY_SHIM_EOF'
import os
import sys
import sysconfig

_exe = os.path.realpath(sys.executable)
_prefix = os.path.dirname(os.path.dirname(_exe))

# Force `sysconfig._CONFIG_VARS` to populate (it's lazily initialized — bare
# attribute access at sitecustomize-import time gives `None`).
_vars = sysconfig.get_config_vars()
for _key, _value in list(_vars.items()):
    if isinstance(_value, str) and "/install" in _value:
        _vars[_key] = _value.replace("/install", _prefix)

_sr = os.environ.get("PG_PYTHON_TARGET_SYSROOT")
_ma = os.environ.get("PG_PYTHON_TARGET_MULTIARCH")
if _sr and _ma:
    _ver = os.environ.get("PG_PYTHON_TARGET_VERSION")
    if not _ver:
        _ver = "%d.%d" % sys.version_info[:2]
    _includepy = "%s/usr/include/python%s" % (_sr, _ver)
    if os.path.isdir(_includepy):
        _vars["LIBDIR"] = "%s/usr/lib/%s" % (_sr, _ma)
        _vars["LIBPL"] = "%s/usr/lib/python%s/config-%s-%s" % (
            _sr,
            _ver,
            _ver,
            _ma,
        )
        _vars["INCLUDEPY"] = _includepy
        _vars["LDLIBRARY"] = "libpython%s.so" % _ver
        _vars["LDVERSION"] = _ver
        _vars["Py_ENABLE_SHARED"] = 1
        _vars["MULTIARCH"] = _ma
    else:
        sys.stderr.write(
            "sitecustomize: PG_PYTHON_TARGET_SYSROOT set but %s is missing;"
            " sysconfig vars left untouched (libpython probes will report"
            " driver-interpreter paths)\\n" % _includepy
        )
PY_SHIM_EOF
        }}

        scrub_pg_config_h() {{
            # `./configure` embeds the actual CC path into
            # `src/include/pg_config.h` (specifically the `VAL_CC`,
            # `VAL_CFLAGS`, `VAL_LDFLAGS`, `VAL_CPPFLAGS` macros that
            # `pg_config --cc` etc. echo back to users at runtime). Under
            # Bazel those are sandbox execroot paths that won't exist outside
            # the build, so substitute with a stable placeholder. This is the
            # autoconf-side equivalent of the Meson
            # `0005-...hack-remove-execroot-from-CC.patch` (which scrubs the
            # same string at `meson.build` evaluation time).
            #
            # IMPORTANT: scrub *only* `pg_config.h`. `src/Makefile.global`
            # uses `$$(CC)` to actually invoke the compiler during make;
            # substituting the path there breaks the build with
            # `cannot open EXECROOT: No such file`. The runtime `pg_config`
            # output is what we care about for reproducibility.
            local workdir="$$1"
            local f="$$workdir/src/include/pg_config.h"
            [ -f "$$f" ] || return 0
            sed -i -E 's|/[^[:space:]"'"'"']+/execroot/|<EXECROOT>/|g' "$$f"
        }}

        run_configure() {{
            local workdir="$$1"; shift
            local python_bin="$$1"; shift
            local python_shim_dir="$$1"; shift
            local configure_args=("$$@");

            # Debian's `/usr/lib/tclConfig.sh` is a redirector that sources
            # `/usr/lib/$$(dpkg-architecture -qDEB_HOST_MULTIARCH)/tcl8.6/tclConfig.sh`
            # by host-absolute path; `dpkg-architecture` is absent in the
            # sandbox, so configure's `--with-tcl` probe finds the redirector
            # but sourcing it fails ("No such file or directory"). When tcl is
            # enabled, point `--with-tclconfig` at the REAL multiarch
            # tclConfig.sh so configure reads it directly; its
            # `-I/usr/include/...` / `-L/usr/lib/...` specs then resolve through
            # the compiler's `--sysroot`.
            for arg in "$${{configure_args[@]}}"; do
                if [ "$$arg" = "--with-tcl" ]; then
                    configure_args+=("--with-tclconfig=$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/tcl8.6")
                    break
                fi
            done

            echo "# $$(date) - run_configure"

            # The C compiler is the planted @libc_sysroot clang wrapper (see
            # module docstring). The C++ compiler (only exercised by
            # `--with-llvm`, for the JIT support library) is the sysroot's
            # clang++ pointed at the same per-PG sysroot — the buildtime
            # closure carries libc6-dev and libstdc++-12-dev, so libc + C++
            # stdlib headers and crt objects all resolve inside the tree.
            local cc="$$SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/bin/clang"
            local cxx="$$SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/bin/clang++ --sysroot=$$SYSROOT_DIR"

            # `-O2` first: PG's configure only applies its default
            # optimization level when CFLAGS is unset; a CFLAGS env that
            # carried only the `-idirafter` entries would silently produce
            # unoptimized binaries.
            #
            # `-idirafter` (not `-I`) so sysroot headers are searched AFTER
            # the compiler's sysroot search path — same rationale as
            # `pg_build.bzl`. The perl `CORE/` entry serves plperl
            # (`perl.h` lives under the multiarch perl dir, which perl's
            # compiled-in ccflags reference by host-absolute path).
            local cflags=(
                "-O2"
                "-idirafter $$SYSROOT_DIR/usr/include"
                "-idirafter $$SYSROOT_DIR/usr/include/$$TARGET_MULTIARCH"
                "-idirafter $$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/perl/$$PERL_VERSION/CORE"
                # pltcl needs `<tcl.h>`. tclConfig.sh's TCL_INCLUDE_SPEC is the
                # host-absolute `-I/usr/include/tcl8.6`, which clang does NOT
                # rewrite through `--sysroot` (only default search paths +
                # `-idirafter` are sysroot-relative), so the configure `<tcl.h>`
                # probe and the pltcl compile both need the sysroot tcl include
                # dir added explicitly.
                "-idirafter $$SYSROOT_DIR/usr/include/tcl8.6"
            )

            # Debian's sysroot splits libraries between `/usr/lib/<arch>/`
            # (most -dev libs) and `/lib/<arch>/` (a small set of base libs
            # like `libsystemd.so.0`); the llvm-14 private lib dir carries
            # the `libLLVM-14.so` dev symlink that `-lLLVM-14` needs (the
            # multiarch dir only has the versioned runtime name). The linker
            # needs all of them on BOTH search paths:
            # - `-L`           for direct `-l<name>` resolution.
            # - `-rpath-link`  for *transitive* DT_NEEDED resolution: when a
            #   directly-linked library (e.g. `libavahi-client.so.3` via
            #   bonjour's `-ldns_sd`) itself has `DT_NEEDED libdbus-1.so.3`,
            #   ld searches only the rpath-link path for the transitive lib,
            #   not `-L`.
            local ldflags=(
                "-L$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH"
                "-L$$SYSROOT_DIR/lib/$$TARGET_MULTIARCH"
                "-L$$SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/lib"
                "-Wl,-rpath-link=$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH"
                "-Wl,-rpath-link=$$SYSROOT_DIR/lib/$$TARGET_MULTIARCH"
                "-Wl,-rpath-link=$$SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/lib"
            )

            # llvm tooling for `--with-llvm`: CLANG is the planted wrapper,
            # used at make time to emit JIT bitcode (`.bc`) — the wrapper
            # bakes `--sysroot=<libc_sysroot>` exactly like the Meson-built
            # `Makefile.global`'s CLANG does. llvm-config + clang++ use the
            # TARGET tree's `$$SYSROOT_DIR/usr/lib/llvm-<N>/bin/` paths (not
            # the EXEC aliases, which are the same files for native builds):
            # configure bakes these strings into the installed
            # `lib/pgxs/src/Makefile.global`, and `scrub_install_tree` rewrites
            # exactly the `/sysroot/usr/lib/llvm-<N>/bin` shape to the
            # persistent @llvm_sysroot path that PGXS extension sandboxes can
            # resolve after this action's sandbox is gone.
            local llvm_config="$$SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/bin/llvm-config"

            # plpython libpython facts: PG's `python.m4` discovers the
            # libpython link/include paths by querying the RUNNING python's
            # `sysconfig`. That interpreter is the rules_python build driver;
            # it drives configure but is not what plpython links. The facts
            # plpython needs are static properties of the sysroot's Debian
            # python: its version is `PYTHON_VERSION` from the release
            # profile and libpython3-dev is in every flavor's buildtime
            # closure. Serve them through the sitecustomize shim (see
            # `set_up_python_shim`) by exporting the sysroot, its multiarch,
            # and the python version; the shim rewrites the embed-relevant
            # config vars to that sysroot's Debian python. Exported (not
            # configure-local) so make-time python invocations see the same
            # answers. plpython then links the release's Debian python and
            # never the driver interpreter.
            export PG_PYTHON_TARGET_SYSROOT="$$SYSROOT_DIR"
            export PG_PYTHON_TARGET_MULTIARCH="$$TARGET_MULTIARCH"
            export PG_PYTHON_TARGET_VERSION="$$PYTHON_VERSION"

            # CPPFLAGS mirrors CFLAGS so autoconf's preprocessor-only probes
            # find sysroot headers (the "accepted by the compiler, rejected
            # by the preprocessor" failure mode).
            #
            # `PYTHON` + `PYTHONPATH`: see `set_up_python_shim`.
            #
            # BISON/FLEX/M4/PERL/PKG_CONFIG/... are exported globals from
            # `set_up_build_env` — configure reads them from the environment
            # and bakes them into `Makefile.global`.
            (
                cd "$$workdir" \\
                && CC="$$cc" \\
                    CXX="$$cxx" \\
                    CLANG="$$cc" \\
                    LLVM_CONFIG="$$llvm_config" \\
                    CFLAGS="$${{cflags[*]}}" \\
                    CPPFLAGS="$${{cflags[*]}}" \\
                    LDFLAGS="$${{ldflags[*]}}" \\
                    PYTHON="$$python_bin" \\
                    PYTHONPATH="$$python_shim_dir" \\
                    ./configure "$${{configure_args[@]}}"
            ) || return $$?

            scrub_pg_config_h "$$workdir"
        }}

        inject_libs() {{
            # Append `-l<lib>` flags to `LIBS` in `src/Makefile.global`
            # *after* configure runs. Used for option-driven link additions
            # PG's autoconf doesn't add itself — currently just `-ldns_sd`
            # for bonjour (see `configure_args::extra_libs_for`). Doing this
            # post-configure (as opposed to passing `LIBS=...` to configure)
            # keeps the flag *out* of every configure probe link, which
            # otherwise pulls the avahi-client → libdbus-1 transitive chain
            # into the very first "does the C compiler work" probe and
            # breaks configure before bonjour even gets considered.
            local workdir="$$1"
            local libs="$$2"
            [ -n "$$libs" ] || return 0
            local f="$$workdir/src/Makefile.global"
            [ -f "$$f" ] || return 0
            sed -i -E "s|^(LIBS = .*)$$|\\1 $$libs|" "$$f"
        }}

        # Each entry has the form `<subdir>|<target1> <target2> ...`.
        # An empty `<subdir>` runs make at the workdir root; otherwise
        # `make -C <workdir>/<subdir>`. The shape is multi-entry so callers
        # can interleave subdir invocations if needed; the current targets
        # produce a single entry per phase (see `make_target_for` /
        # `make_install_target_for` in `configure_args.bzl`, which return
        # `world-bin`/`install-world-bin` — PG 14+'s "everything except
        # docs" target — when contrib is enabled).
        run_make_phase() {{
            local phase="$$1"; shift
            local workdir="$$1"; shift
            local installdir="$$1"; shift
            local entries=("$$@");

            echo "# $$(date) - run_make_$$phase"

            for entry in "$${{entries[@]}}"; do
                local subdir="$${{entry%%|*}}"
                local targets="$${{entry##*|}}"
                local make_dir="$$workdir"
                if [ -n "$$subdir" ]; then
                    make_dir="$$workdir/$$subdir"
                fi
                local extra=()
                if [ -n "$$installdir" ]; then
                    extra+=("DESTDIR=$$installdir")
                fi
                # FLEXFLAGS=-noline keeps `#line` directives out of
                # generated parsers (reproducibility — the autoconf-side
                # counterpart of the Meson pgflex `--noline` patches).
                # BISON_PKGDATADIR / M4 / PERL5LIB are inherited from the
                # `set_up_build_env` exports so make-time tool invocations
                # also find their data files.
                # shellcheck disable=SC2086
                "$$MAKE_BIN" \\
                    -C "$$make_dir" \\
                    -j"$$JOBS" \\
                    FLEXFLAGS=-noline \\
                    "$${{extra[@]}}" \\
                    $$targets || return $$?
            done
        }}

        verify_install() {{
            # Sanity-check the post-`make install` tree: `pg_config` MUST live
            # at `<installdir><prefix>/bin/pg_config`. Downstream consumers
            # (the PGXS toolchain target, the introspect pipeline) rely on
            # that path; if the install layout drifted, fail fast with a
            # clear message rather than silently producing an empty or
            # misshapen artifact.
            local installdir="$$1"
            local prefix="$$2"
            local pg_config="$$installdir$$prefix/bin/pg_config"
            if [ ! -x "$$pg_config" ]; then
                echo "verify_install: pg_config not found at $$pg_config" >&2
                echo "  Expected file at \\$$INSTALLDIR\\$$INSTALL_PREFIX/bin/pg_config." >&2
                echo "  Either PG's install layout changed (re-check the build_options'" >&2
                echo "  prefix_distro) or 'make install[-world-bin]' did not populate" >&2
                echo "  the binary. Inspect the build log above this line for the" >&2
                echo "  underlying failure." >&2
                return 1
            fi
        }}

        scrub_install_tree() {{
            # Post-install rewrite of `lib/pgxs/src/Makefile.global`, the
            # autoconf-side twin of `pg_build.bzl`'s
            # `_STRIP_SANDBOX_PATHS_POSTFIX` (see the rationale there).
            # configure captured CC/CLANG/CXX/LLVM_CONFIG and CFLAGS/LDFLAGS
            # verbatim from this action's environment; once the sandbox is
            # torn down those paths are dead and downstream PGXS extension
            # builds would fail to invoke `$$(CLANG)` for JIT bitcode.
            #
            # Step 1 strips the sandbox prefix so absolute paths under sandbox
            # execroots collapse to `/<install_base>/...`.
            # Step 2 redirects the planted `/sysroot/usr/lib/llvm-<N>/bin/
            # clang` wrapper symlink (word-anchored) to the persistent
            # @libc_sysroot wrapper via `$(LIBC_SYSROOT_DIR)`.
            # Step 3 rewrites the remaining action-time
            # `/sysroot/usr/lib/llvm-<N>/bin` tool paths (llvm-config,
            # clang++) to the persistent @llvm_sysroot bin dir via
            # `$(LLVM_SYSROOT_DIR)` (same Debian llvm-14 binaries, same APT
            # snapshot).
            local installdir="$$1"

            echo "# $$(date) - scrub_install_tree"

            find "$$installdir" -name 'Makefile.global' -print0 \\
                | xargs -0 --no-run-if-empty \\
                    sed -i -E \\
                        -e 's|/sandbox/linux-sandbox/[0-9]+/execroot/[^/]+/|/|g' \\
                        -e "s|/sysroot/usr/lib/llvm-$$LLVM_MAJOR/bin/clang\\b|/$(LIBC_SYSROOT_DIR)/usr/lib/llvm-$$LLVM_MAJOR/bin/clang|g" \\
                        -e "s|/sysroot/usr/lib/llvm-$$LLVM_MAJOR/bin|/$(LLVM_SYSROOT_DIR)/usr/lib/llvm-$$LLVM_MAJOR/bin|g"
        }}

        emit_introspect_json() {{
            # Walk the source tree + post-install tree and synthesize a
            # meson-shape introspect JSON. Mirrors what `meson introspect`
            # emits for the meson build path so Layer 2
            # (`pg_introspect_version_repo`) consumes both flavors uniformly.
            # Runs under the hermetic rules_python interpreter (the chroot has
            # no system python3).
            local synth_script="$$1"; shift
            local workdir="$$1"; shift
            local installdir="$$1"; shift
            local prefix="$$1"; shift
            local out="$$1"; shift

            echo "# $$(date) - emit_introspect_json"

            "$$PYTHON_BIN" "$$synth_script" \\
                --workdir "$$workdir" \\
                --installdir "$$installdir" \\
                --prefix "$$prefix" \\
                --out "$$out"
        }}

        stage_test_libs() {{
            # Capture the regression support modules (regress.so, plus
            # refint.so/autoinc.so) into pkglibdir so core pg_regress finds them
            # on --dlpath with no build tree. PG's autoconf install never ships
            # regress.so (only the never-default `install-tests` target), and
            # refint/autoinc reach lib/postgresql only under install-world-bin;
            # all three are always BUILT into $$WORKDIR/src/test/regress/ by
            # `make all`, so copy them from there. Mirrors the meson postfix.
            local workdir="$$1"; shift
            local installdir="$$1"; shift
            local prefix="$$1"; shift

            echo "# $$(date) - stage_test_libs"

            local src_dir="$$workdir/src/test/regress"
            local dst_dir="$$installdir$$prefix/lib/postgresql"
            mkdir -p "$$dst_dir"
            local mod
            for mod in regress refint autoinc; do
                local found="$$src_dir/$$mod.so"
                if [ -f "$$found" ]; then
                    cp -f "$$found" "$$dst_dir/"
                fi
            done
        }}

        stage_test_bin() {{
            # The libpq TAP suites (interfaces/libpq/tap) run libpq_uri_regress +
            # libpq_testclient by bare name, and the pg_bsd_indent TAP suite runs
            # pg_bsd_indent. PG's `world-bin` builds neither
            # src/interfaces/libpq/test nor src/tools/pg_bsd_indent (both
            # `install: false` developer/test helpers), so build them here and
            # stage the programs into test_bin/, which the harness puts on the TAP
            # PATH. Mirrors the meson _TEST_MODULES_CAPTURE, scoped to the
            # test-helper dirs the make introspect renders: src/test/modules suites are
            # not installed by make, so they are never enumerated.
            local workdir="$$1"; shift
            local installdir="$$1"; shift
            local prefix="$$1"; shift

            echo "# $$(date) - stage_test_bin"

            local dst_dir="$$installdir$$prefix/test_bin"
            mkdir -p "$$dst_dir"

            # libpq test helpers.
            local libpq_test_dir="$$workdir/src/interfaces/libpq/test"
            if [ -d "$$libpq_test_dir" ]; then
                "$$MAKE_BIN" -C "$$libpq_test_dir" -j"$$JOBS" FLEXFLAGS=-noline all \\
                    || return $$?
                local prog
                for prog in libpq_uri_regress libpq_testclient; do
                    if [ -x "$$libpq_test_dir/$$prog" ]; then
                        cp -f "$$libpq_test_dir/$$prog" "$$dst_dir/"
                    fi
                done
            fi

            # pg_bsd_indent: a standalone source-formatting tool whose
            # t/001_pg_bsd_indent.pl runs it by bare name on PATH. world-bin
            # does not build it (install: false upstream), so build it here.
            # Built serially: it is seven source files, so -j buys nothing and
            # avoids racing its order-only submake-generated-headers /
            # submake-libpgport prerequisites under recursive make. A missing
            # binary after a clean make is a staging bug, not a no-op, so fail
            # loudly rather than silently shipping a test_bin/ without it.
            local indent_dir="$$workdir/src/tools/pg_bsd_indent"
            if [ -d "$$indent_dir" ]; then
                "$$MAKE_BIN" -C "$$indent_dir" FLEXFLAGS=-noline all
                if [ -x "$$indent_dir/pg_bsd_indent" ]; then
                    cp -f "$$indent_dir/pg_bsd_indent" "$$dst_dir/"
                else
                    echo "stage_test_bin: pg_bsd_indent not produced by make" >&2
                    ls -la "$$indent_dir" >&2 || true
                    exit 1
                fi
            fi
        }}

        tar_install() {{
            local tar_file="$$1"; shift
            local installdir="$$1"; shift

            echo "# $$(date) - tar_install"

            local tar_args=(
                "--format=posix"
                "--numeric-owner"
                "--owner=0"
                "--group=0"
            )

            LC_ALL=C "$$BSDTAR" \\
                -cf "$$tar_file" \\
                "$${{tar_args[@]}}" \\
                --directory "$$installdir" \\
                .
        }}

        # Diagnostic helper called when the build pipeline exits non-zero.
        # Appends an env dump + a trailer pointing at LOG_FILE. The work block
        # output is already in LOG_FILE via the `| tee "$$LOG_FILE"` pipeline
        # below; this just adds forensic state. Not wired to an `ERR` trap
        # because the pipeline mask + `set -o pipefail` interactions make the
        # trap unreliable; we trigger it from the explicit PIPESTATUS check.
        emit_error_footer() {{
            local rc="$$1"
            {{
                echo
                echo "# $$(date) - rc=$$rc - LAST_CMD=$$BASH_COMMAND"
                env
            }} >> "$$LOG_FILE"

            {{
                echo
                echo "========================================================"
                echo "  >> LOG: $${{LOG_FILE#"$$EXT_BUILD_ROOT/"}}"
                echo "========================================================"
                echo
            }} | tee /dev/stderr >> "$$LOG_FILE"
        }}

        DEBUG="{debug}"
        [ "$$DEBUG" != True ] || set -x

        # =================================================================== #

        export EXT_BUILD_ROOT="$$PWD"

        TAR_FILE="$$EXT_BUILD_ROOT/{tar_file}"
        LOG_FILE="$$EXT_BUILD_ROOT/{log_file}"
        INTROSPECT_JSON="$$EXT_BUILD_ROOT/{introspect_json_file}"
        INTROSPECT_SYNTH_SCRIPT="$$EXT_BUILD_ROOT/{synth_script}"
        ANTLR_CPP_SRC_DIR="$$EXT_BUILD_ROOT/{antlr_cpp_srcs}"
        ANTLR_JAR_PATH="$$EXT_BUILD_ROOT/{antlr_jar}"
        PG_SRC="$$EXT_BUILD_ROOT/{pg_src}"
        SYSROOT_TAR="$$EXT_BUILD_ROOT/{sysroot_tar}"
        EXEC_SYSROOT_TAR="$$EXT_BUILD_ROOT/{exec_sysroot_tar}"
        CLANG_WRAPPER="$$EXT_BUILD_ROOT/{clang_wrapper}"
        SYSROOT_SETUP="$$EXT_BUILD_ROOT/{sysroot_setup}"
        EXEC_SYSROOT_SETUP="$$EXT_BUILD_ROOT/{exec_sysroot_setup}"
        PYTHON_BIN="$$EXT_BUILD_ROOT/{python_bin}"
        BSDTAR="$$EXT_BUILD_ROOT/$(BSDTAR_BIN)"
        LLVM_MAJOR="{llvm_major}"
        PERL_VERSION="{perl_version}"
        PYTHON_VERSION="{python_version}"

        CONFIGURE_ARGS=(
{configure_args_array}
        )
        EXTRA_LIBS="{extra_libs_str}"
        MAKE_TARGETS=(
{make_targets_array}
        )
        MAKE_INSTALL_TARGETS=(
{make_install_targets_array}
        )
        EXTRAS=(
{extras_array}
        )
        INSTALL_PREFIX="{install_prefix}"
        CONTRIB_ENABLED="{contrib_enabled}"
        TAP_TESTS_ENABLED="{tap_tests_enabled}"

        WORKDIR="$$EXT_BUILD_ROOT/build_tmp"
        INSTALLDIR="$$EXT_BUILD_ROOT/install_tmp"
        PYTHON_SHIM_DIR="$$EXT_BUILD_ROOT/python_shim"

        export LOG_FILE

        # Stream the build output to LOG_FILE AND to bazel's stderr via a tee
        # process (rather than the simpler block-redirect to LOG_FILE). Two
        # reasons:
        #
        # 1. `tee` is line-buffered, so partial output is preserved if the script
        #    aborts mid-step. A simple block redirect relies on the shell's IO
        #    buffers being flushed on abort, which empirically does NOT happen
        #    reliably under genrule-setup.sh's `set -e -u -o pipefail` regime —
        #    LOG_FILE ended up containing only the error trailer.
        #
        # 2. Surfacing the build log directly in bazel's error output makes the
        #    actual failure visible without the user having to chase down
        #    `bazel-out/.../tar.log`. The error footer below still points at
        #    LOG_FILE for completeness.
        {{
            set_up_sysroots
            set_up_build_env

            # NOTE:
            # autoconf+make builds write into the source tree (config.status,
            # generated parser .c files, .o objects next to sources). PG_SRC is
            # a tree artifact (read-only in Bazel) so copy the tree to a
            # writable workdir first; chmod because `cp -aL` preserves mode and
            # tree-artifact files come back read-only.
            cp -raL "$$PG_SRC" "$$WORKDIR"

            merge_extras "$$WORKDIR" "$${{EXTRAS[@]}}"

            chmod -R u+w "$$WORKDIR"

            set_up_python_shim "$$PYTHON_SHIM_DIR"

            run_configure "$$WORKDIR" "$$PYTHON_BIN" "$$PYTHON_SHIM_DIR" \\
                "$${{CONFIGURE_ARGS[@]}}"

            inject_libs "$$WORKDIR" "$$EXTRA_LIBS"

            run_make_phase "build" "$$WORKDIR" "" \\
                "$${{MAKE_TARGETS[@]}}"
            run_make_phase "install" "$$WORKDIR" "$$INSTALLDIR" \\
                "$${{MAKE_INSTALL_TARGETS[@]}}"

            # Sanity-check the install tree (pg_config in expected location)
            # before downstream consumers (PGXS pass, introspect synth) use
            # it. Fails fast on layout drift.
            verify_install "$$INSTALLDIR" "$$INSTALL_PREFIX"

            # Overlay contribs are gated on `contrib=true` for the same
            # reason PG's own contribs are: when contrib is disabled, the
            # build is PG core only (make target `all`), and a `barebones` /
            # `minimal` install shouldn't ship the overlay's contribs either.
            # Runs BEFORE scrub_install_tree so the staged Makefile.global
            # still carries this action's live tool paths.
            if [ "$$CONTRIB_ENABLED" = "True" ]; then
                pgxs_install_extras "$$WORKDIR" "$$INSTALLDIR" "$$INSTALL_PREFIX" \\
                    "$${{EXTRAS[@]}}"
            else
                echo "# $$(date) - pgxs_install_extras: skipped (contrib=false)"
            fi

            scrub_install_tree "$$INSTALLDIR"

            # Stage regress.so/refint.so/autoinc.so from the build tree into the
            # install tree (PG's autoconf install never ships regress.so; see
            # stage_test_libs). Runs before tar_install so the libs ride in the
            # `:tar` artifact `_install_tree` extracts; the harness reads them
            # from the unpacked `lib/postgresql/` on --dlpath.
            stage_test_libs "$$WORKDIR" "$$INSTALLDIR" "$$INSTALL_PREFIX"

            # Build + stage the libpq TAP helper programs into test_bin/ for the
            # test variant only (tap_tests=enabled); production builds skip the
            # extra make + ship no test_bin/.
            if [ "$$TAP_TESTS_ENABLED" = "True" ]; then
                stage_test_bin "$$WORKDIR" "$$INSTALLDIR" "$$INSTALL_PREFIX"
            fi

            # The introspect synth wants prefix-relative paths
            # (`bin/postgres`, `share/postgresql/extension/*.control`, ...),
            # the same convention meson emits. `make install
            # DESTDIR=$$INSTALLDIR` + `--prefix=$$INSTALL_PREFIX` puts files
            # at `$$INSTALLDIR$$INSTALL_PREFIX/...`, so point the synth at
            # that subdir. The tar itself keeps the prefix in its entries
            # (downstream tar consumers expect that).
            emit_introspect_json \\
                "$$INTROSPECT_SYNTH_SCRIPT" \\
                "$$WORKDIR" \\
                "$$INSTALLDIR$$INSTALL_PREFIX" \\
                "$$INSTALL_PREFIX" \\
                "$$INTROSPECT_JSON"

            tar_install "$$TAR_FILE" "$$INSTALLDIR"
        }} 2>&1 | tee "$$LOG_FILE"
        rc=$${{PIPESTATUS[0]}}
        if [ "$$rc" -ne 0 ]; then
            emit_error_footer "$$rc"
            exit "$$rc"
        fi
    """

    cmd = cmd_template.format(
        tar_file = "$(execpath %s)" % tar_file,
        log_file = "$(execpath %s)" % log_file,
        introspect_json_file = "$(execpath %s)" % introspect_json_file,
        synth_script = "$(execpath %s)" % introspect_synth_script,
        antlr_cpp_srcs = "$(execpath %s)" % antlr_cpp_runtime_srcs,
        antlr_jar = "$(execpath %s)" % antlr_jar,
        extras_array = extras_array,
        contrib_enabled = "%s" % contrib_enabled,
        tap_tests_enabled = "%s" % tap_tests_enabled,
        pg_src = "$(execpath %s)" % pg_src,
        sysroot_tar = "$(execpath %s)" % sysroot_tar,
        exec_sysroot_tar = "$(execpath %s)" % exec_sysroot_tar,
        clang_wrapper = "$(execpath %s)" % _SYSROOT_CLANG_WRAPPER,
        sysroot_setup = "$(execpath %s)" % _SYSROOT_SETUP_SCRIPT,
        exec_sysroot_setup = "$(execpath %s)" % _EXEC_SYSROOT_SETUP_SCRIPT,
        python_bin = "$(execpath %s)" % _PYTHON_BIN,
        perl_bin = "$(execpath %s)" % _PERL_BIN,
        perl_config_overrides = "$(execpath %s)" % _PERL_CONFIG_OVERRIDES,
        llvm_major = LLVM_MAJOR,
        perl_version = _PERL_VERSION,
        python_version = _PYTHON_VERSION,
        configure_args_array = configure_args_array,
        extra_libs_str = extra_libs_str,
        make_targets_array = make_targets_array,
        make_install_targets_array = make_install_targets_array,
        install_prefix = prefix,
        debug = "%s" % debug,
    )

    native.genrule(
        name = name,
        srcs = srcs,
        outs = [tar_file, log_file, introspect_json_file],
        cmd = cmd,
        tools = tools,
        target_compatible_with = select({
            # bsdtar.exe doesn't support the flags we use.
            "@platforms//os:windows": ["@platforms//:incompatible"],
            "//conditions:default": [],
        }),
        toolchains = [
            "@bsd_tar_toolchains//:resolved_toolchain",
            # Declared for its FILE SET, not for `$(CC)` (see module docstring):
            # the resolved cc_toolchain's `all_files` carry the
            # `@llvm_toolchain_<arch>` adapter binaries (Debian clang) and the
            # @libc_sysroot tree (wired in via `llvm.toolchain_root` /
            # `llvm.sysroot`). The planted clang wrapper self-discovers both via
            # `readlink -f $0` path arithmetic, and the hermetic sandbox
            # materializes inputs as hardlinks (readlink stays inside the
            # chroot), so the wrapper's exec target and --sysroot tree must be
            # declared inputs to exist there.
            "@bazel_tools//tools/cpp:current_cc_toolchain",
            # `$(LIBC_SYSROOT_DIR)` / `$(LLVM_SYSROOT_DIR)` make variables for
            # `scrub_install_tree`'s Makefile.global rewrite (persistent bzlmod
            # repo paths resolved at analysis time; never appearing in
            # human-authored source).
            "@monogres//toolchains/libc_sysroot:libc_sysroot_dir",
            "@monogres//toolchains/llvm_sysroot:llvm_sysroot_dir",
        ],
        visibility = ["//visibility:public"],
    )

def pg_build_make(
        name,
        pg_src,
        build_options,
        introspect_synth_script,
        antlr_cpp_runtime_srcs,
        antlr_jar,
        sysroot_tar,
        exec_sysroot_tar,
        extra_sources = {},
        auto_features = "disabled",
        debug = False):
    """Build PostgreSQL with the autoconf+make build system.

    Translates the Meson-shaped `build_options` to autoconf `./configure` flags
    via `configure_args.to_configure_args`, optionally merges sibling source
    trees into the primary tree at the configured `contrib_dir` paths
    (`metadata.extra_sources`), then runs `./configure && make TARGET && make
    INSTALL_TARGET DESTDIR=...` against the per-PG sysroot pair (extracted at
    action time exactly like `pg_build`). The choice between `make
    all`/`install` and `make world-bin`/`install-world-bin` is keyed off the
    `contrib` option: `contrib=true` selects the `world-bin` variants (core +
    contrib, no docs) and additionally runs the post-install PGXS pass over
    overlay contribs.

    The macro emits a `:tar` artifact (the install dir, tarred), a `:logs`
    alias, a `:toolchain` template-variable target, and an `:introspect`
    filegroup pointing at the meson-shape introspect JSON synthesized by
    `introspect_synth_script` after `make install` (the make-side counterpart of
    the meson path's separate `meson(targets=["introspect"])` run).

    Patch equivalences vs. the Meson PG patches:
    - `prefix_distro` (Meson option) → translated to `--prefix` (autoconf
      separates the embedded path from install staging natively, with `DESTDIR=`
      controlling the latter).
    - pgflex env-propagation / `--noline` patches → not applicable;
      autoconf+make calls flex directly. Reproducibility is achieved here by
      passing `FLEXFLAGS=-noline` on the `make` command line.
    - `execroot` scrub from CC → `scrub_pg_config_h` shell function in this
      build script (post-configure sed on `src/include/pg_config.h` only).
    - contrib disable → not needed; autoconf splits this at the make-target
      level (`all` vs `world-bin`).

    Args:
        name (str): Bazel target name. `:<name>` is the extracted install tree
            (`_install_tree`); the underlying genrule is `:<name>.genrule` with
            `<name>.tar`, `<name>.log`, `<name>.introspect.json` outputs.
        pg_src (str): Label of the per-version `:dir` on the source repo (e.g.
            `"@pg_src//15.0:dir"`), a tree artifact keyed on the archive and the
            patches it was made from.
        build_options (dict): Meson option name → value, as produced by
            `flavors.FLAVORS[<flavor>].build_options(...)`. Translated to
            autoconf flags by `to_configure_args`. The `contrib` option (if
            present and truthy) selects the `world-bin` make targets.
        introspect_synth_script (str): Label of the
            `pg_build_make_introspect.py` script (e.g.
            `"@monogres//tools:pg_build_make_introspect.py"`). The genrule
            invokes it post-`make install` (under the hermetic python
            interpreter) to synthesize the meson-shape introspect JSON consumed
            by Layer 2 + gen_contrib.
        antlr_cpp_runtime_srcs (str): Label of a tree artifact containing the
            antlr4-cpp-runtime source files (typically
            `//utils:antlr4_cpp_runtime_srcs`, which extracts the BCR
            `@antlr4-cpp-runtime` cc_library's `srcs`/`hdrs`/`textual_hdrs`).
            The shell pre-step `build_antlr_runtime` compiles a clean (no
            Abseil) `libantlr4-runtime.a` from these sources before
            `babelfishpg_tsql` is built. Required for all make builds even
            though only `babelfishpg_tsql` uses it; the gate is in the shell,
            not the macro signature.
        antlr_jar (str): Label of the ANTLR4 Java tool jar (typically
            `@antlr_jar//:jar`). Used to override the version-pinned jar
            embedded in babelfish's source tree so the generated parser code
            matches the runtime version (`@antlr4-cpp-runtime`).
        sysroot_tar (str): The per-PG `:sysroot_tar` alias label (rendered
            per-version by `versions.bzl`, arch-selected). Extracted at action
            time by `sysroot_setup.sh` into `$EXT_BUILD_ROOT/sysroot`; provides
            the build's libs, headers, AND build tools (make, bison, flex, m4,
            perl, pkg-config, llvm). Required: the make path cannot build PG
            without a sysroot (there is no host fallback under the hermetic
            sandbox).
        exec_sysroot_tar (str): The `:exec_sysroot_tar` label (the
            `exec_files`-wrapped `:sysroot_tar` resolved in EXEC config).
            Materialized at `$EXT_BUILD_ROOT/exec_sysroot` (symlinked to the
            target tree for native builds); all tools that RUN during the build
            resolve from it. Required, same as `sysroot_tar`.
        extra_sources (dict): Catalog `metadata.extra_sources` mapping (`{<key>:
            {...}}`) of sibling source trees merged into the primary `pg_src`
            tree at their configured in-tree destinations before `./configure`;
            each is a `:dir` tree artifact like `pg_src`. Empty (`{}`) for
            single-source flavors.
        auto_features (str): Meson `auto_features` value. Accepted for API
            symmetry with `pg_build` (the per-target BUILD files render the same
            kwargs for both build systems) and ignored: the autoconf+make path
            has no `--auto-features` counterpart and does not consume it.
        debug (bool): If `True`, the build script enables `set -x`.
    """

    # buildifier: disable=unused-variable
    _ = auto_features

    if not sysroot_tar or not exec_sysroot_tar:
        fail("pg_build_make requires sysroot_tar + exec_sysroot_tar (the " +
             "make path sources its compiler and build tools from the per-PG " +
             "sysroot; there is no host fallback)")

    configure_args = to_configure_args(build_options, debug = debug)
    extra_libs = extra_libs_for(build_options)
    targets = make_target_for(build_options)
    install_targets = make_install_target_for(build_options)

    # Resolve the configured install prefix from build_options. This is the
    # `--prefix` value autoconf bakes into pg_config and is what
    # `verify_install` uses to locate `pg_config` under the staging `DESTDIR`.
    # Fall back to autoconf's default prefix when unset.
    prefix = build_options.get("prefix_distro", "/usr/local/pgsql")

    # The genrule produces the raw tar + log + introspect JSON outputs. The
    # public `:<name>` target below is the `_install_tree` wrapper that consumes
    # the genrule's tar and exposes `OutputGroupInfo.gen_dir` for downstream
    # `declare_outputs` consumers (contrib extension packaging). The genrule's
    # own name is `:<name>.genrule` (private); its output filenames stay
    # `<name>.tar` / `<name>.log` / `<name>.introspect.json` so file-label
    # consumers (the `:logs` alias, the `:introspect` filegroup) keep resolving.
    #
    # The `contrib` build option gates both the PG `world-bin` make targets and
    # the overlay PGXS pass; resolve it once here for the genrule's shell guard
    # and the `_install_tree` binary list below.
    contrib_value = build_options.get("contrib")
    contrib_enabled = (
        contrib_value == True or
        (type(
            contrib_value,
        ) == "string" and contrib_value.lower() in ("enabled", "true"))
    )

    # The test-enabled build variant flips tap_tests=enabled; gate the libpq TAP
    # helper build + test_bin/ staging on it (production builds keep neither).
    tap_tests_enabled = build_options.get("tap_tests") == "enabled"

    tar_file = "%s.tar" % name
    log_file = "%s.log" % name
    introspect_json_file = "%s.introspect.json" % name
    _pg_build_make_genrule(
        name = "%s.genrule" % name,
        tar_file = tar_file,
        log_file = log_file,
        introspect_json_file = introspect_json_file,
        pg_src = pg_src,
        configure_args = configure_args,
        extra_libs = extra_libs,
        make_targets = targets,
        make_install_targets = install_targets,
        extra_sources = extra_sources,
        sysroot_tar = sysroot_tar,
        exec_sysroot_tar = exec_sysroot_tar,
        prefix = prefix,
        contrib_enabled = contrib_enabled,
        tap_tests_enabled = tap_tests_enabled,
        introspect_synth_script = introspect_synth_script,
        antlr_cpp_runtime_srcs = antlr_cpp_runtime_srcs,
        antlr_jar = antlr_jar,
        debug = debug,
    )

    # Binaries exposed as template variables by `_install_tree` so the
    # `:toolchain` target maps each `<install_dir>/bin/<binary>` to an uppercase
    # variable (e.g. `pg_config` -> `PG_CONFIG`). Matches the set the Meson path
    # declares via `out_binaries`, including the contrib-gated extras only when
    # contrib is enabled in this option set. psql drives pg_regress (it shells
    # out to psql per test); pg_ctl stops the --temp-instance postmaster.
    # Matches the meson out_binaries set so `$(PSQL)`/`$(PG_CTL)` resolve on
    # both paths; both are already in the install `bin/`, so this only adds the
    # `:toolchain` template-vars (no tar change).
    pg_binaries = ["initdb", "postgres", "pg_config", "pg_isready", "psql", "pg_ctl"]
    if contrib_enabled:
        pg_binaries += ["oid2name", "vacuumlo"]

    _install_tree(
        name = name,
        tar = tar_file,
        binaries = pg_binaries,
        visibility = ["//visibility:public"],
    )

    pg_template_variable_info(
        name = "toolchain",
        target = name,
        visibility = ["//visibility:public"],
    )

    # `:introspect` filegroup points at the meson-shape introspect JSON
    # synthesized by `introspect_synth_script` as the third output of the
    # genrule above. Mirrors the meson side's `:introspect` (where it's a
    # separate `meson(targets=["introspect"])` invocation). Tagged `manual` so
    # it only builds when explicitly requested (e.g. by the introspect JSON
    # generator), same as the meson `:introspect`.
    native.filegroup(
        name = "introspect",
        srcs = [introspect_json_file],
        tags = ["manual"],
        visibility = ["//visibility:public"],
    )

    # Mirror `pg_build.bzl`'s `:logs` target so debugging conventions are the
    # same across build systems.
    native.alias(
        name = "logs",
        actual = log_file,
        visibility = ["//visibility:public"],
    )
