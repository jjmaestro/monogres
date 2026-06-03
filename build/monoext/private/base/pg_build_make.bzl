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

def _shell_array(values):
    """Render a Starlark list of strings as a bash array literal."""
    if not values:
        return ""
    return "\n".join(["                \"%s\"" % v for v in values])

def _pg_build_make_genrule(
        name,
        pg_src,
        configure_args,
        extra_libs,
        make_targets,
        make_install_targets,
        sysroot_tar,
        exec_sysroot_tar,
        prefix,
        introspect_synth_script,
        debug):
    tar_file = "%s.tar" % name
    log_file = "%s.log" % name
    introspect_json_file = "%s.introspect.json" % name

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
        _SYSROOT_SETUP_SCRIPT,
        _EXEC_SYSROOT_SETUP_SCRIPT,
        _PYTHON_BIN,
        _PYTHON_FILES,
        introspect_synth_script,
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

            export SYSROOT_DIR EXEC_SYSROOT_DIR TARGET_MULTIARCH
        }}

        set_up_build_env() {{
            echo "# $$(date) - set_up_build_env"

            # Tools that RUN during configure/make resolve from the EXEC tree
            # (native builds: identical to the target tree). The llvm bin dirs
            # carry llvm-config plus the planted clang wrapper; `find`-style
            # probes with no env-var override (msgfmt for nls, tclsh for tcl,
            # pkg-config) resolve via PATH.
            local path=(
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

            # perl from the sysroot. `sysroot_setup.sh` sed-patched this
            # perl's `Config.pm` / `Config_heavy.pl` to sysroot-rooted paths
            # (archlib, libpth), and planted the multiarch `libperl.so` into
            # the `perl/<V>/CORE/` dir — so `ExtUtils::Embed::ldopts` (plperl)
            # emits `-L` flags that resolve inside the extracted tree.
            # PERL5LIB makes the interpreter's module tree resolvable under
            # the hermetic chroot: the compiled-in @INC paths under
            # `/usr/lib/<arch>/` are covered by the chroot symlinks, but
            # `/usr/share/perl/<V>` (perl-modules: strict.pm, ExtUtils, ...)
            # is not, so list the sysroot copies explicitly.
            export PERL="$$EXEC_SYSROOT_DIR/usr/bin/perl"
            local perl5lib=(
                "$$EXEC_SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/perl-base"
                "$$EXEC_SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/perl/$$PERL_VERSION"
                "$$EXEC_SYSROOT_DIR/usr/share/perl/$$PERL_VERSION"
            )
            export PERL5LIB="$$(IFS=:; echo "$${{perl5lib[*]}}")"

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

            echo "# $$(date) - run_configure"

            # The C compiler is the planted @libc_sysroot clang wrapper (see
            # module docstring). The C++ compiler (only exercised by
            # `--with-llvm`, for the JIT support library) is the sysroot's
            # clang++ pointed at the same per-PG sysroot — the buildtime
            # closure carries libc6-dev and libstdc++-12-dev, so libc + C++
            # stdlib headers and crt objects all resolve inside the tree.
            local cc="$$SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/bin/clang"
            local cxx="$$EXEC_SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/bin/clang++ --sysroot=$$SYSROOT_DIR"

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

            # llvm tooling for `--with-llvm`: llvm-config (queried by
            # configure for version/flags/libs) runs on the build host, so it
            # resolves from the EXEC tree; CLANG is the planted wrapper, used
            # at make time to emit JIT bitcode (`.bc`) — the wrapper bakes
            # `--sysroot=<libc_sysroot>` exactly like the Meson-built
            # `Makefile.global`'s CLANG does.
            local llvm_config="$$EXEC_SYSROOT_DIR/usr/lib/llvm-$$LLVM_MAJOR/bin/llvm-config"

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
        INSTALL_PREFIX="{install_prefix}"

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
            # before downstream consumers (introspect synth) use it. Fails
            # fast on layout drift.
            verify_install "$$INSTALLDIR" "$$INSTALL_PREFIX"

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
        pg_src = "$(execpath %s)" % pg_src,
        sysroot_tar = "$(execpath %s)" % sysroot_tar,
        exec_sysroot_tar = "$(execpath %s)" % exec_sysroot_tar,
        clang_wrapper = "$(execpath %s)" % _SYSROOT_CLANG_WRAPPER,
        sysroot_setup = "$(execpath %s)" % _SYSROOT_SETUP_SCRIPT,
        exec_sysroot_setup = "$(execpath %s)" % _EXEC_SYSROOT_SETUP_SCRIPT,
        python_bin = "$(execpath %s)" % _PYTHON_BIN,
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
        ],
        visibility = ["//visibility:public"],
    )

def pg_build_make(
        name,
        pg_src,
        build_options,
        introspect_synth_script,
        sysroot_tar,
        exec_sysroot_tar,
        debug = False):
    """Build PostgreSQL with the autoconf+make build system.

    Translates the Meson-shaped `build_options` to autoconf `./configure` flags
    via `configure_args.to_configure_args`, then runs `./configure && make
    TARGET && make INSTALL_TARGET DESTDIR=...` against the per-PG sysroot pair
    (extracted at action time exactly like `pg_build`). The choice between `make
    all`/`install` and `make world-bin`/`install-world-bin` is keyed off the
    `contrib` option: `contrib=true` selects the `world-bin` variants (core +
    contrib, no docs).

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
        name (str): Bazel target name. Emits `<name>.tar` and `<name>.log`.
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
        debug (bool): If `True`, the build script enables `set -x`.
    """
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

    _pg_build_make_genrule(
        name = name,
        pg_src = pg_src,
        configure_args = configure_args,
        extra_libs = extra_libs,
        make_targets = targets,
        make_install_targets = install_targets,
        sysroot_tar = sysroot_tar,
        exec_sysroot_tar = exec_sysroot_tar,
        prefix = prefix,
        introspect_synth_script = introspect_synth_script,
        debug = debug,
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
        srcs = ["%s.introspect.json" % name],
        tags = ["manual"],
        visibility = ["//visibility:public"],
    )

    # Mirror `pg_build.bzl`'s `:logs` target so debugging conventions are the
    # same across build systems.
    native.alias(
        name = "logs",
        actual = "%s.log" % name,
        visibility = ["//visibility:public"],
    )
