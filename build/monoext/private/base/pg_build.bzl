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
load(":compat.bzl", "is_compatible_with")
load(":toolchain.bzl", "pg_template_variable_info")

# Action-time setup script: extracts the per-PG sysroot tar into
# `$EXT_BUILD_ROOT/sysroot/`, sed-patches perl's `Config.pm` / `Config_heavy.pl`
# in place for the hermetic chroot, symlinks the @libc_sysroot clang wrapper
# into the extracted tree (so meson canonicalizes the symlink into the wrapper's
# persistent absolute path when baking `CLANG` into `Makefile.global`), and
# prints the sysroot absolute path on stdout for `SYSROOT_DIR`.
_SYSROOT_LIB = "@monogres//monoext/private/base:sysroot_lib.sh"
_SYSROOT_SETUP_SCRIPT = "@monogres//monoext/private/base:sysroot_setup.sh"
_EXEC_SYSROOT_SETUP_SCRIPT = "@monogres//monoext/private/base:exec_sysroot_setup.sh"

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

def _meson_common_args(
        pg_src,
        build_options,
        auto_features,
        sysroot_tar = None,
        exec_sysroot_tar = None,
        src_dir = None):
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

    # `data` (target cfg) for sysroot_tar (and the wrapper it carries), so the
    # select() on `@platforms//cpu:*` resolves to the TARGET arch. RFCC's
    # `build_data` is `cfg = "exec"` which would resolve to the host arch and
    # silently break cross-compile (host=amd64 picks the amd64 sysroot tar while
    # linking against an arm64 target). The action's input set is the union of
    # `data + build_data` (framework.bzl:612), so both are equally available at
    # action time; only the configuration differs.
    data = []
    if src_dir:
        # The source tree (target cfg), so `$(execpath src_dir)` below resolves
        # to its Bazel-computed root (`external/<repo>/<v>/gh`) for the
        # `__FILE__` prefix-map. `src_dir` is the `:dir_path` alias, the same
        # directory rules_foreign_cc reads as `lib_source`, so this adds no new
        # action input.
        data.append(src_dir)
    if sysroot_tar:
        # The tar is the only `:sysroot_tar` artifact consumers see; the full
        # normalized tree lives inside. At action time the setup script extracts
        # it, sed-patches perl Config, and symlinks the clang wrapper. The
        # wrapper label is added separately because meson's canonicalize-symlink
        # step needs to resolve it to a persistent absolute path (not the
        # sandbox-extracted copy).
        data.append(sysroot_tar)
        data.append(_SYSROOT_CLANG_WRAPPER)
        build_data.append(_SYSROOT_LIB)
        build_data.append(_SYSROOT_SETUP_SCRIPT)

        # `exec_sysroot_tar` is the same `:sysroot_tar` artifact resolved in
        # EXEC config via the `exec_files` rule at the version-root BUILD, so
        # the inner `@platforms//cpu:*` select() picks the host arch's tar
        # regardless of `--platforms`. Under cross-compile (host=amd64,
        # target=arm64) this materializes a parallel amd64 sysroot tree at
        # `$EXEC_SYSROOT_DIR` carrying build-machine tools (msgfmt, etc.) that
        # PG meson invokes via `find_program(..., native: true)` during
        # configure. For native builds the tars are bzlmod-deduplicated to the
        # same file; the setup script realpath-compares and symlinks the exec
        # dir to the target dir to skip the ~1GB second extraction.
        if exec_sysroot_tar:
            data.append(exec_sysroot_tar)
            build_data.append(_EXEC_SYSROOT_SETUP_SCRIPT)

    toolchains = [
        "@rules_m4//m4:current_m4_toolchain",
        "@rules_flex//flex:current_flex_toolchain",
        "@rules_bison//bison:current_bison_toolchain",
        "@bsd_tar_toolchains//:resolved_toolchain",
        "@monogres//toolchains/libc_sysroot:libc_sysroot_dir",
        "@monogres//toolchains/libc_sysroot:libc_sysroot_exec_dir",
        "@monogres//toolchains/llvm_sysroot:llvm_sysroot_dir",
        "@monogres//toolchains/llvm_sysroot:llvm_sysroot_exec_dir",
        _PERL_TOOLCHAIN,
        _PYTHON_TOOLCHAIN,
    ]

    # Map the build-time source root out of `__FILE__`: PostgreSQL bakes the
    # source path of every translation unit into `.rodata` (via the `__FILE__`
    # in elog/ereport/assert), so the embedded path depends on the build layout
    # unless canonicalized. `$$PG_SRC_PREFIX` (resolved in env_sysroot below) is
    # the build-relative source root the compiler sees; stripping it leaves the
    # package-relative path (`src/...`, `contrib/...`).
    macro_prefix_map = (
        ["-fmacro-prefix-map=$$PG_SRC_PREFIX="] if src_dir else []
    )

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
            # Third-party (non-core) modules land in the unversioned vendor dir,
            # e.g. IPC::Run (libipc-run-perl) at usr/share/perl5/IPC/Run.pm. The
            # test-enabled build variant flips meson `tap_tests=enabled`, whose
            # configure gate (config/check_modules.pl) `use`s IPC::Run; without
            # this entry @INC misses it. Inert for production builds.
            "$$PERL_SYSROOT_DIR/usr/share/perl5",
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
            # EXEC-arch sysroot paths exposed as shell env vars so downstream
            # values (LD_LIBRARY_PATH below, cross_binaries' llvm-config path,
            # etc.) reference shell variables that expand at action time. The
            # right-hand side uses `$(LIBC_SYSROOT_EXEC_DIR)` /
            # `$(LLVM_SYSROOT_EXEC_DIR)` make variables provided by the
            # `sysroot_exec_dir` instances in `//toolchains/libc_sysroot/` and
            # `//toolchains/llvm_sysroot/`, which resolve in EXEC config (`cfg =
            # "exec"` on their `target` attr) so they always point at the host
            # arch's sysroot regardless of `--platforms`.
            LIBC_SYSROOT_EXEC_DIR = "$$EXT_BUILD_ROOT/$(LIBC_SYSROOT_EXEC_DIR)",
            LIBC_SYSROOT_EXEC_MULTIARCH = "$(LIBC_SYSROOT_EXEC_MULTIARCH)",
            LLVM_SYSROOT_EXEC_DIR = "$$EXT_BUILD_ROOT/$(LLVM_SYSROOT_EXEC_DIR)",
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
            # `EXEC_SYSROOT_DIR`: parallel EXEC-arch per-PG sysroot tree. The
            # exec_sysroot_setup.sh script realpath-compares the target and exec
            # tars; for NATIVE builds (same file) it symlinks `exec_sysroot ->
            # sysroot` to skip a redundant ~1GB extraction. For CROSS builds the
            # tars differ and a second extraction populates
            # `$EXT_BUILD_ROOT/exec_sysroot` with the EXEC arch's
            # bin/lib/include tree. The dict-iteration order matters: this
            # value's `$()` runs AFTER `SYSROOT_DIR` (the symlink in the native
            # fast-path targets `$EXT_BUILD_ROOT/sysroot` which the setup script
            # just created).
            EXEC_SYSROOT_DIR = (
                "$$(sh $(execpath {exec_setup}) $(execpath {tar}) " +
                "$(execpath {exec_tar}) $(BSDTAR_BIN))"
            ).format(
                exec_setup = _EXEC_SYSROOT_SETUP_SCRIPT,
                tar = sysroot_tar,
                exec_tar = exec_sysroot_tar,
            ) if exec_sysroot_tar else "$$EXT_BUILD_ROOT/sysroot",
            # `TARGET_MULTIARCH`: the Debian multiarch dirname for the TARGET
            # arch (e.g. `x86_64-linux-gnu` or `aarch64-linux-gnu`). From
            # `$(LIBC_SYSROOT_MULTIARCH)`, the target-config libc sysroot's
            # tuple (`toolchains` make-variables resolve in the genrule's TARGET
            # config, so this is the build's target arch, not the host). The
            # tuple is a pure arch fact, identical across the target sysroots
            # (the libc sysroot and the per-PG sysroot pin the same
            # Debian-snapshot arch), so it names the per-PG sysroot's lib dir
            # too. Mirrors the exec side's `$(LIBC_SYSROOT_EXEC_MULTIARCH)`. Set
            # right after SYSROOT_DIR so all downstream multiarch-aware env vars
            # below expand through it.
            TARGET_MULTIARCH = "$(LIBC_SYSROOT_MULTIARCH)",
            PKG_CONFIG_SYSROOT_DIR = "$$SYSROOT_DIR",
            PKG_CONFIG_PATH = ":".join([
                "$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/pkgconfig",
                "$$SYSROOT_DIR/usr/share/pkgconfig",
            ]),
            CFLAGS = " ".join(macro_prefix_map + [
                "-idirafter $$SYSROOT_DIR/usr/include",
                "-idirafter $$SYSROOT_DIR/usr/include/$$TARGET_MULTIARCH",
                "-idirafter $$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/perl/" + _PERL_VERSION + "/CORE",
            ]),
            CXXFLAGS = " ".join(macro_prefix_map + [
                "-idirafter $$SYSROOT_DIR/usr/include",
                "-idirafter $$SYSROOT_DIR/usr/include/$$TARGET_MULTIARCH",
                "-idirafter $$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/perl/" + _PERL_VERSION + "/CORE",
            ]),
            # `LIBRARY_PATH` is the conventional GCC/Clang env for additional
            # link-time `-L` search dirs; it works for NATIVE builds (host arch
            # == target arch). For CROSS builds, clang's driver intentionally
            # SKIPS `LIBRARY_PATH` (`Linker::ConstructJob` in clang's source
            # gates it on `!TC.isCrossCompiling()`). So `-lzstd` and other
            # `dependency()`-discovered libs whose `.pc` files emit `-L/usr/lib`
            # (stripped by pkg-config as a system path, leaving just `-l<name>`)
            # fall through to the cc_toolchain's `--sysroot=` (libc_sysroot) and
            # come up empty (libc_sysroot doesn't carry libzstd etc.).
            #
            # `LDFLAGS` is read by meson and prepended to every link command, so
            # the `-L` flags pass through to ld.lld regardless of cross/native
            # mode. Same path either way: per-PG sysroot's multiarch lib dir
            # (where libzstd, libssl, libcrypto, libxml2, libxslt, etc. live).
            LDFLAGS = "-L$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH",
            # Debian's multi-arch layout splits libs between `/lib/<arch>`
            # (libcrypt, libtinfo, libz) and `/usr/lib/<arch>` (libz3); both are
            # needed in LD_LIBRARY_PATH because the hermetic Linux sandbox has
            # no host `/lib` fallback for runtime tool invocations (perl +
            # llvm-config + msgfmt).
            #
            # EXEC vs TARGET split: under cross-compile, exec-config host tools
            # (python3 from @python_sysroot, perl from @perl_sysroot, the meson
            # interpreter, etc.) run during action setup and need their NEEDED
            # libs at the HOST arch. The per-PG `$$SYSROOT_DIR` is the TARGET
            # arch (where final binaries link); host tools loading TARGET libs
            # via this LD_LIBRARY_PATH fail with `cannot open shared object
            # file`.
            #
            # `$(LIBC_SYSROOT_EXEC_DIR)` / `$(LIBC_SYSROOT_EXEC_MULTIARCH)` come
            # from `//toolchains/libc_sysroot:libc_sysroot_exec_dir`, a
            # `sysroot_exec_dir` instance whose `target` attr is `cfg = "exec"`.
            # That forces the underlying arch-selecting alias to resolve in EXEC
            # config, so the make-variable always points at the host arch's
            # sysroot regardless of `--platforms`. The plain
            # `$(LIBC_SYSROOT_DIR)` / `$(LIBC_SYSROOT_MULTIARCH)` analogues
            # resolve in TARGET config (where `select()` in `toolchains = ...`
            # genrule attrs evaluates); `TARGET_MULTIARCH` above uses the latter
            # for the per-PG sysroot's target lib dir.
            #
            # `$$LLVM_SYSROOT_EXEC_DIR/lib/$$LIBC_SYSROOT_EXEC_MULTIARCH` is
            # required by llvm-config and other LLVM host tools whose NEEDED
            # libs include `libtinfo.so.6` and `libz.so.1`, which Debian ships
            # under `@llvm_sysroot`'s `lib/<multiarch>/` rather than
            # `@libc_sysroot`'s. NOTE: the EXEC multiarch is shared between
            # sysroots since both pin the same Debian-snapshot architecture.
            #
            # Prepended so host tools find their libs first; target paths follow
            # for build-time-only TARGET tool invocations and link-time -L
            # resolution. The `$$EXT_BUILD_ROOT` prefix is the action's CWD.
            LD_LIBRARY_PATH = ":".join([
                "$$LIBC_SYSROOT_EXEC_DIR/lib/$$LIBC_SYSROOT_EXEC_MULTIARCH",
                "$$LIBC_SYSROOT_EXEC_DIR/usr/lib/$$LIBC_SYSROOT_EXEC_MULTIARCH",
                "$$LLVM_SYSROOT_EXEC_DIR/lib/$$LIBC_SYSROOT_EXEC_MULTIARCH",
                "$$LLVM_SYSROOT_EXEC_DIR/usr/lib/$$LIBC_SYSROOT_EXEC_MULTIARCH",
                # EXEC per-PG sysroot lib dirs: covers private libs of
                # build-machine tools that meson invokes during configure /
                # build (msgfmt -> libgettextsrc-*.so, etc.). For native builds
                # the path resolves to the same dir as $SYSROOT_DIR/...
                # (symlinked in exec_sysroot_setup.sh) so this is a no-op
                # duplicate; under cross-compile it points at the EXEC-arch tree
                # so amd64 ELFs find their .so deps.
                "$$EXEC_SYSROOT_DIR/usr/lib/$$LIBC_SYSROOT_EXEC_MULTIARCH",
                "$$EXEC_SYSROOT_DIR/lib/$$LIBC_SYSROOT_EXEC_MULTIARCH",
                "$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH",
                "$$SYSROOT_DIR/usr/lib",
                "$$SYSROOT_DIR/lib/$$TARGET_MULTIARCH",
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
            PERL_DEBIAN_ARCHLIB = "$$SYSROOT_DIR/usr/lib/$$TARGET_MULTIARCH/perl/" + _PERL_VERSION,
        )

    # `PG_SRC_PREFIX`: the source root as the compiler sees it in `__FILE__`,
    # for the prefix-map (`macro_prefix_map` above). `$(execpath src_dir)` gives
    # the Bazel-computed source root (`external/<repo>/<v>/gh`,
    # execroot-relative); rules_foreign_cc runs the compiler from
    # `$BUILD_TMPDIR`, so the baked `__FILE__` is that root relative to the
    # build dir. `$BUILD_TMPDIR` is `$EXT_BUILD_ROOT/<build-rel>`, so the climb
    # is one `..` per component of `<build-rel>` (sed turns each into `..`);
    # prepending it to the source root yields the same relative path meson
    # bakes. Pure bash so busybox `realpath` (no `--relative-to`) is not needed.
    # Prepended so the shell expands it when CFLAGS / CXXFLAGS are exported.
    if src_dir:
        env_sysroot = {
            "PG_SRC_PREFIX": (
                "$$(echo $${BUILD_TMPDIR#$$EXT_BUILD_ROOT/} | " +
                "sed 's#[^/][^/]*#..#g')/$(execpath %s)/"
            ) % src_dir,
        } | env_sysroot

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
        # `$$LLVM_SYSROOT_EXEC_DIR/usr/lib/llvm-14/bin` first so meson's
        # `find_program('llvm-config')` (config-tool dependency lookup, e.g.
        # PG's `dependency('llvm', method: 'config-tool')`) picks the EXEC
        # arch's llvm-config. The TARGET arch's binary at
        # `$$SYSROOT_DIR/usr/lib/llvm-14/bin/llvm-config` can't run on the build
        # host under cross-compile; the EXEC binary returns the same version +
        # flags (same APT snapshot) regardless of arch, so the query result is
        # correct for the target build.
        path_components.append(
            "$$LLVM_SYSROOT_EXEC_DIR/usr/lib/llvm-" + LLVM_MAJOR + "/bin",
        )

        # `$$EXEC_SYSROOT_DIR/usr/bin` before `$$SYSROOT_DIR/usr/bin` so PG
        # meson's `find_program(..., native: true)` picks build-machine binaries
        # (msgfmt for NLS, etc.) before falling back to the TARGET arch's bins
        # (which would be aarch64 ELFs under cross-compile and fail to exec on
        # the amd64 host). For native builds the two paths resolve to the same
        # directory (exec_sysroot_setup.sh symlinks exec_sysroot -> sysroot) so
        # ordering is a no-op.
        path_components.append("$$EXEC_SYSROOT_DIR/usr/bin")
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

    # `cross_binaries` / `native_binaries` are consumed by RFCC's patched
    # `meson` rule to emit `--cross-file` / `--native-file` `[binaries]` entries
    # during `meson setup`. Both `_pg_build_meson` and `_pg_build_introspect`
    # thread this dict through so they resolve the same build-machine tools
    # (e.g. `llvm-config` for PG's `dependency('llvm', method =
    # 'config-tool')`). Under `cross_compile = True`, PATH-based search is
    # refused ("Default target is not allowed for cross use"), so the cross-file
    # pin is what lets meson find llvm-config; an empty `cross_binaries` here
    # would fail the LLVM query in any meson run (full build or introspect).
    cross_binaries = {
        "llvm-config": "$LLVM_SYSROOT_EXEC_DIR/usr/lib/llvm-" + LLVM_MAJOR + "/bin/llvm-config",
    } if sysroot_tar else {}

    # env_sysroot must be merged first so SYSROOT_DIR is set before other
    # variables that reference it (PKG_CONFIG_SYSROOT_DIR, etc.) The
    # test-enabled build variant (tap_tests=enabled) additionally lifts
    # src/test/modules fixtures into the install tree (see
    # _TEST_MODULES_CAPTURE) so the `modules:` suites can load them; production
    # keeps the postfix to the sandbox-path rewrite + regress support modules
    # only.
    postfix = _STRIP_SANDBOX_PATHS_POSTFIX
    if build_options.get("tap_tests") == "enabled":
        postfix += _TEST_MODULES_CAPTURE

    return dict(
        build_data = build_data,
        cross_binaries = cross_binaries,
        data = data,
        env = env_sysroot | env | env_meson,
        lib_source = pg_src,
        native_binaries = {},
        options = build_options | meson_tool_options,
        postfix_script = postfix,
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
# Step 2 redirects `/sysroot/usr/lib/llvm-14/bin/clang` (word-anchored) to the
# @libc_sysroot `clang_wrapper.sh` shim via `$(LIBC_SYSROOT_DIR)`. Postgres's
# runtime JIT path invokes `$(CLANG)` DIRECTLY to emit-llvm-IR; no cc_toolchain
# features inject `--sysroot=`, so the unwrapped clang would compile against
# host headers (no host in the hermetic sandbox; in the production container we
# want the deterministic Debian sysroot). The wrapper bakes
# `--sysroot=<libc_sysroot>` into every invocation. The `\\b` boundary keeps
# `clang-14`, `clang++`, etc. routed through `@llvm_sysroot` directly (step 3;
# they're only invoked by the build, not by runtime JIT).
#
# Step 3 rewrites the action-time `/sysroot/usr/lib/llvm-14/bin` prefix (where
# the tar-extracted Debian libllvm14 binaries lived during the action) to the
# persistent `@llvm_sysroot` bin dir via `$(LLVM_SYSROOT_DIR)`. Both paths point
# at the same Debian llvm-14 binaries (same APT_SNAPSHOT); the rewrite swaps the
# per-action sandbox location for the install-base-bind-mount- persistent one so
# PGXS extensions invoking `$(LLVM_BINPATH)/llvm-lto` succeed after sandbox
# teardown.
#
# `$(LLVM_SYSROOT_DIR)` and `$(LIBC_SYSROOT_DIR)` are make variables provided by
# `//toolchains/llvm_sysroot:llvm_sysroot_dir` and
# `//toolchains/libc_sysroot:libc_sysroot_dir` (`sysroot_dir` rule from
# `//sysroots/toolchains/`); the canonical bzlmod repo name resolves at analysis
# time, never appearing in source.

_STRIP_SANDBOX_PATHS_POSTFIX = """\
find "$$INSTALLDIR" -name 'Makefile.global' -print0 \\
    | xargs -0 --no-run-if-empty \\
        sed -i -E \\
            -e 's|/sandbox/linux-sandbox/[0-9]+/execroot/[^/]+/|/|g' \\
            -e "s|/sysroot/usr/lib/llvm-{major}/bin/clang\\b|/$(LIBC_SYSROOT_DIR)/usr/lib/llvm-{major}/bin/clang|g" \\
            -e "s|/sysroot/usr/lib/llvm-{major}/bin|/$(LLVM_SYSROOT_DIR)/usr/lib/llvm-{major}/bin|g"

# Capture the regression support modules (regress.so, plus refint.so/autoinc.so
# on PG<18) into pkglibdir. They are built with `install: false` (pg_test_mod_args),
# so `meson install` never emits them, yet core pg_regress needs regress.so on
# `--dlpath` (test_setup.sql does `CREATE FUNCTION ... AS '@libdir@/regress.so'`)
# and the trigger tests need refint/autoinc. They are still BUILT by the default
# `meson compile`, so copy them out of the build dir into the install tree.
mkdir -p "$$INSTALLDIR/lib/postgresql"
for mod in regress refint autoinc; do
    found=$$(find "$$BUILD_TMPDIR" -name "$$mod.so" -type f 2>/dev/null | head -1)
    if [ -n "$$found" ]; then cp -f "$$found" "$$INSTALLDIR/lib/postgresql/"; fi
done
""".format(major = LLVM_MAJOR)

# Capture src/test/modules test fixtures into the install tree. Appended to the
# meson postfix only for the test-enabled build variant (tap_tests=enabled); the
# production tree never ships test fixtures.
#
# Why this is needed (and is not a meson-native install): PostgreSQL marks every
# src/test/modules module `install: false` (pg_test_mod_args) on purpose; they
# are test fixtures, not shipped artifacts. No meson option installs them,
# `meson install` skips them by definition, and rules_foreign_cc's `out_*`
# capture is install-dir-relative so it cannot reach them either. Upstream runs
# them via `meson test` against the BUILD tree (pointing dynamic_library_path /
# extension_control_path at the build dir), never an installed tree. Our harness
# runs pg_regress against the installed `:tar`, so the only way to make the
# `modules:` regress and isolation suites work is to lift the built fixtures
# into the tree here, as the regress-support capture above does for the same
# `install: false` reason.
#
# The capture has three parts. The module `.so` (built by `meson compile` into
# $$BUILD_TMPDIR) is copied into pkglibdir, which for this libdir=lib build is
# `lib/` itself (alongside the contrib .so), NOT `lib/postgresql/` (that subdir
# only holds the --dlpath regress-support libs); so `LOAD '<name>'` and `CREATE
# EXTENSION` resolve `$$libdir/<name>`. The `.control` and extension scripts
# (`<name>--<ver>.sql`) are static SOURCE files; rules_foreign_cc builds meson
# out-of-source, so they live under $$EXT_BUILD_ROOT, not $$BUILD_TMPDIR, and we
# search both roots. The test executables (test_escape, libpq_pipeline,
# test_json_parser_*) are run by a TAP suite by bare name on PATH (IPC::Run);
# like the rest they are `install: false`, so they never reach bin/, and the set
# varies by version (test_escape is PG18+, test_json_parser_* PG17+,
# libpq_pipeline 16+). The libpq TAP suites likewise drive libpq_uri_regress and
# libpq_testclient (src/interfaces/libpq/test/), and pg_bsd_indent's TAP suite
# drives pg_bsd_indent (src/tools/pg_bsd_indent/); both are `install: false`
# too, yet built by default. Capture every +x file directly under those test
# dirs (excluding the .so and the .p/ build intermediates) into a dedicated
# test_bin/ tree rather than naming each one. out_data_dirs captures the whole
# tree; the harness puts test_bin/ on PATH for the TAP lane.
_TEST_MODULES_CAPTURE = """
mkdir -p "$$INSTALLDIR/share/extension" "$$INSTALLDIR/test_bin"
find "$$BUILD_TMPDIR" -path '*/src/test/modules/*' -name '*.so' -type f \\
    -exec cp -f {} "$$INSTALLDIR/lib/" \\;
for __src_root in "$$BUILD_TMPDIR" "$$EXT_BUILD_ROOT"; do
    find "$$__src_root" -path '*/src/test/modules/*' \\
        \\( -name '*.control' -o -name '*--*.sql' \\) -type f \\
        -exec cp -f {} "$$INSTALLDIR/share/extension/" \\; 2>/dev/null || true
done
find "$$BUILD_TMPDIR" \\( -path '*/src/test/modules/*' \\
    -o -path '*/src/interfaces/libpq/test/*' \\
    -o -path '*/src/tools/pg_bsd_indent/*' \\) -type f -perm -100 \\
    ! -path '*/*.p/*' ! -name '*.so' \\
    -exec cp -f {} "$$INSTALLDIR/test_bin/" \\;
"""

def _pg_build_meson(
        name,
        pg_src,
        build_options,
        version,
        auto_features,
        pg_base_version = None,
        sysroot_tar = None,
        exec_sysroot_tar = None):
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

    # The test-enabled variant (tap_tests=enabled) additionally installs the
    # client/server tools the TAP suites drive by bare name (a standby test runs
    # pg_basebackup, a dump test runs pg_dump). They must land in a real bin/
    # alongside lib/, because a tool such as pg_createsubscriber starts the
    # server via find_other_exec, which resolves "postgres" relative to the
    # calling binary and only relocates pkglibdir from a "bin/" dir. The
    # production set above stays curated; these are core src/bin tools.
    if build_options.get("tap_tests") == "enabled":
        pg_binaries.extend([
            # psql drives pg_regress (it shells out to psql to run each test's
            # SQL); pg_ctl stops the --temp-instance postmaster.
            "psql",
            "pg_ctl",
            "pg_basebackup",
            "pg_receivewal",
            "pg_recvlogical",
            "pg_dump",
            "pg_dumpall",
            "pg_restore",
            "pg_rewind",
            "pg_waldump",
            "pg_amcheck",
            "pg_controldata",
            "pg_resetwal",
            "pg_checksums",
            "pg_archivecleanup",
            "pg_verifybackup",
            "pg_test_fsync",
            "pg_test_timing",
            "createdb",
            "dropdb",
            "createuser",
            "dropuser",
            "clusterdb",
            "vacuumdb",
            "reindexdb",
            "pgbench",
            "pg_upgrade",
            "ecpg",
        ])

        # pg_combinebackup, pg_walsummary, and pg_createsubscriber are src/bin
        # tools added in PG17; gate on the upstream PostgreSQL base
        # (pg_base_version, not the flavor's own version number) so the curated
        # list stays valid on PG16 while PG17-based forks (e.g. IvorySQL >= 4.0)
        # still capture them.
        if is_compatible_with(pg_base_version or version, ">=17.0"):
            pg_binaries.extend([
                "pg_combinebackup",
                "pg_walsummary",
                "pg_createsubscriber",
            ])

    # including lib in out_data_dirs because even when it's out_lib_dir's
    # default, it's not included in declared_outputs
    out_data_dirs = [
        "lib",
        "share",
    ]

    # The test variant also stages the install:false src/test helpers into
    # test_bin/ (see _TEST_MODULES_CAPTURE), captured as a whole tree since the
    # set varies by version; the harness puts test_bin/ on the TAP PATH.
    if build_options.get("tap_tests") == "enabled":
        out_data_dirs.append("test_bin")

    # The `:dir_path` sibling of `pg_src` is the extracted source directory;
    # passing it lets `_meson_common_args` resolve the source root for the
    # `__FILE__` prefix-map via `$(execpath)` (Bazel-computed) rather than a
    # hand-built path. It is the path that is wanted here and not the contents,
    # which is what `:dir_path` is for: `:dir` is a copy of the same tree, and
    # its Bazel-computed root is that copy's, not the one meson compiles from.
    # `pg_src` is the `@<src>//<v>` lib_source label.
    src_dir = pg_src + ":dir_path"

    meson_common_args = _meson_common_args(
        pg_src = pg_src,
        build_options = build_options,
        auto_features = auto_features,
        sysroot_tar = sysroot_tar,
        exec_sysroot_tar = exec_sysroot_tar,
        src_dir = src_dir,
    )

    meson(**(meson_common_args | dict(
        name = name,
        # The patched `rules_foreign_cc` `meson` rule (see
        # `//patches/rules_foreign_cc:0003-meson-cross-compile-flag.patch`)
        # emits a meson cross-file under `$BUILD_TMPDIR` and passes it to `meson
        # setup --cross-file`. `needs_exe_wrapper = true` in the cross-file
        # makes meson skip the `add_languages('c')` sanity check that runs a
        # target-arch test binary on the host (the failure mode the
        # cross-compile case hits, where the binary's PT_INTERP / NEEDED don't
        # exist on the host). Passed unconditionally because the cross-file
        # faithfully mirrors the resolved cc_toolchain, so native PG builds get
        # the same `c` / `cpp` / `ar` / `strip` they would otherwise get via env
        # vars. The visible difference for native builds is the skipped
        # `__int128 alignment bug` `cc.run` check (gated on
        # `meson.is_cross_build()` in Postgres `meson.build`), which is the
        # accepted "hope for the best" path Postgres takes for cross-compiles.
        cross_compile = True,
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

def _pg_build_introspect(
        name,
        pg_src,
        build_options,
        auto_features,
        sysroot_tar = None,
        exec_sysroot_tar = None):
    meson_common_args = _meson_common_args(
        pg_src = pg_src,
        build_options = build_options,
        auto_features = auto_features,
        sysroot_tar = sysroot_tar,
        exec_sysroot_tar = exec_sysroot_tar,
    )

    meson(**(meson_common_args | dict(
        name = "introspect",
        # Mirror `_pg_build_meson`'s `cross_compile` so introspect-only
        # invocations get the same `meson setup` configuration (see notes
        # there). Without this, an introspect run against an arm64 target
        # platform would still try to execute the host-unrunnable
        # `add_languages('c')` sanity binary.
        cross_compile = True,
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

def pg_build(
        name,
        pg_src,
        build_options,
        version,
        auto_features,
        pg_base_version = None,
        sysroot_tar = None,
        exec_sysroot_tar = None):
    """
    Generates a Bazel target to build Postgres with the Meson build system.

    This rule configures the environment and invokes the rules_foreign_cc
    `meson` rule, using preconfigured options, toolchains, etc.

    Args:
        name (str): The name of the Bazel target to generate.
        pg_src (str): The external Bazel repo with the Postgres source code.
        build_options (dict): Meson build options that configure optional
            Postgres features and other compilation parameters.
        version (str): The flavor's version (e.g. "16.11" for postgres, "5.0"
            for IvorySQL). Used as the fallback PG base when `pg_base_version`
            is not supplied.
        pg_base_version (str): The upstream PostgreSQL major.minor this build is
            based on (for the `postgres` flavor, equal to `version`). Gates the
            PG17 src/bin backup tools in the test variant's captured set on the
            real PostgreSQL version rather than the flavor's own version number.
            Defaults to `version`.
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
        exec_sysroot_tar (str): Optional `:exec_sysroot_tar` label (the
            `exec_files`-wrapped `:sysroot_tar` rendered alongside it). At
            action time materializes a parallel EXEC-arch sysroot tree at
            `$EXT_BUILD_ROOT/exec_sysroot` (symlinked to `sysroot` for native
            builds; extracted separately for cross). Its `usr/bin` is prepended
            to `PATH` so meson's `find_program(..., native: true)` picks
            build-machine tools (msgfmt, etc.) before falling back to the TARGET
            arch's bins.
    """

    _pg_build_meson(
        name,
        pg_src,
        build_options,
        version,
        auto_features,
        pg_base_version,
        sysroot_tar,
        exec_sysroot_tar,
    )

    _pg_build_introspect(
        name,
        pg_src,
        build_options,
        auto_features,
        sysroot_tar,
        exec_sysroot_tar,
    )

    pg_template_variable_info(
        name = "toolchain",
        target = name,
        visibility = ["//visibility:public"],
    )
