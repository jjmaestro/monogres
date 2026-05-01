"""
Layout adapter for the Debian LLVM tree in `@llvm_sysroot`.

`toolchains_llvm` v1.7.0 requires a canonical clang+llvm tarball layout under
its `toolchain_root`: `bin/<tool>` for every tool in `_toolchain_tools`,
`lib/clang/<version>/...` for the resource dir, and a `BUILD.bazel` whose
filegroups match `@toolchains_llvm//toolchain:BUILD.llvm_repo.tpl`. Debian's
clang-<V> ships at `usr/lib/llvm-<V>/bin/<tool>` and
`usr/lib/llvm-<V>/lib/clang/<version>/`, incompatible with that contract at
three sites in `configure.bzl`:

  - `_toolchain_tools` symlink loop (`rctx.symlink(... + "bin/" + tool, ...)`,
    fails if any source is absent),
  - `_cc_toolchain_str` `cxx_builtin_include_directories` (literal
    `include/c++/v1`, `lib/clang/<ver>/include`),
  - `cc_wrapper.sh.tpl` runtime guard (`[[ ! -f
    ${toolchain_path_prefix}bin/clang ]]`).

This rule hardlinks `@llvm_sysroot`'s `usr/lib/llvm-<V>/` tree into its own repo
root (cheap because they share the Bazel cache filesystem; whole- directory
symlinks would not work because Bazel's package `glob([...])` does not traverse
directory symlinks across repo boundaries). Each arch instantiates its own repo
so the hardlinked files resolve to the matching
`@llvm_sysroot//debian/12/<arch>` tree.

The BUILD.bazel emitted matches the filegroup NAMES that `toolchains_llvm`
expects, but is tailored for our stdlib = stdc++ setup: filegroups that the
upstream template populates from libc++-shipped paths (`include/c++/v1`,
`lib/libc++*.a`, `lib/libunwind.a`) accept empty globs (Debian's llvm-<V>
doesn't bundle libc++, and our libstdc++ comes from `@libc_sysroot`). Explicit
`allow_empty = True` keeps the project's `--incompatible_disallow_empty_glob`
from failing the package load.

Validation: `bazel build @<name>//:clang` confirms the canonical filegroup
resolves to a real `bin/clang` file.
"""

load("@sysroots//apt:layout.bzl", _multiarch = "multiarch")

def _impl(rctx):
    # `sysroot` is a Label inside `@llvm_sysroot//debian/12/<arch>`. Take the
    # path's dirname to anchor on that per-arch sysroot directory.
    sysroot_label_path = rctx.path(rctx.attr.sysroot)
    arch_root = sysroot_label_path.dirname
    llvm_major = rctx.attr.llvm_version.split(".")[0]
    debian_llvm = "%s/usr/lib/llvm-%s" % (arch_root, llvm_major)
    debian_multiarch = _multiarch(rctx.attr.arch)

    # Hardlink the entire `usr/lib/llvm-14/` tree (bin/, lib/, include/, cmake/,
    # ...) into this repo's root via `cp -alL`. Whole-directory symlinks would
    # be simpler but Bazel's package-loading `glob([...])` does NOT traverse
    # directory symlinks across repo boundaries, so the canonical filegroups
    # (`:clang`, `:ld`, `:lib`, ...) in the rendered BUILD.bazel would come up
    # empty. Hardlinks present as real files to glob and stay space-cheap (same
    # filesystem inside Bazel's cache; no content duplication).
    #
    # `-L` follows symlinks: Debian's `usr/lib/llvm-14/lib/libLLVM-14.so.1` is a
    # relative symlink (`../../x86_64-linux-gnu/libLLVM-14.so.1`) pointing into
    # the multiarch path. The relative target lives outside our adapter root, so
    # a plain `cp -a` would leave a dangling symlink and ld.so would fail with
    # `cannot open shared object file: No such file or directory` when loading
    # clang. `-L` resolves through to the real file in the sysroot's multiarch
    # dir and hardlinks the resolved content into our `lib/` so the
    # canonical-layout name `lib/libLLVM-14.so.1` resolves to a real file. Same
    # logic applies to `bin/ld64.lld -> lld` (intra-bin) and any other symlinks
    # Debian's packaging uses.
    result = rctx.execute([
        "cp",
        "-alL",
        "%s/." % debian_llvm,
        str(rctx.path(".")),
    ])
    if result.return_code != 0:
        fail("cp -alL from %s failed (%d): %s" % (
            debian_llvm,
            result.return_code,
            result.stderr,
        ))

    # `libLLVM.so`'s transitive deps live in Debian's multiarch lib dir(s).
    # Historically Debian split them across the top-level `/lib/<multiarch>/`
    # (early-load libs like liblzma, libtinfo, libz) and `/usr/lib/<multiarch>/`
    # (libedit, libxml2, libffi, libgssapi-krb5, ...). Once the /usr-merge
    # completed in the package payloads (Debian 13+), everything ships under a
    # single `/usr/lib/<multiarch>/` and the top-level `/lib/<multiarch>/` is
    # absent from the extracted sysroot. Hardlink whichever of the two exist
    # into `<adapter>/lib/` so `LD_LIBRARY_PATH=<adapter>/lib` in the wrapper
    # resolves the whole chain. `--no-clobber` keeps content already placed by
    # the prior `cp -alL` (e.g. `libLLVM.so.*` which the
    # `usr/lib/llvm-<major>/lib/` step pulled in via symlink-deref) untouched.
    for src_dir in [
        "%s/usr/lib/%s" % (arch_root, debian_multiarch),
        "%s/lib/%s" % (arch_root, debian_multiarch),
    ]:
        if not rctx.path(src_dir).exists:
            continue
        result_multiarch = rctx.execute([
            "cp",
            "-alL",
            "--no-clobber",
            "%s/." % src_dir,
            "%s/lib/" % str(rctx.path(".")),
        ])
        if result_multiarch.return_code != 0:
            fail("cp -alL --no-clobber from %s failed (%d): %s" % (
                src_dir,
                result_multiarch.return_code,
                result_multiarch.stderr,
            ))

    # Wrap every ELF binary in `bin/` with a tiny shim that exports
    # `LD_LIBRARY_PATH=<adapter>/lib` (for the Debian-shipped `.so` deps) before
    # exec'ing the real binary at `<adapter>/bin/<tool>.real`. Reason:
    # `toolchains_llvm`'s `cc_toolchain_config.bzl` binds most `tool_paths`
    # entries (ar / ld / nm / objcopy / strip / dwp / cov / profdata / objdump)
    # directly to the binary path, bypassing `cc_wrapper.sh`. Only `gcc` and
    # `parse_headers` go through the wrapper. The wrapper's LD_LIBRARY_PATH
    # patch covers compile / link driven by the clang frontend; ar / objcopy /
    # etc. need their own shim to satisfy `rules_foreign_cc`'s direct `$AR` /
    # `$NM` invocations during autoconf-style probes (citus, GNU make bootstrap,
    # etc.).
    #
    # The shim builds the adapter's `bin/` from the execroot it derives from
    # `$0` (`${shim_path%%/external/*}` strips everything past `/external/`),
    # then re-appends `external/<this_repo_canonical_name>/bin/`. The canonical
    # name is substituted at adapter-build time via `rctx.name`, the same
    # mechanism `toolchains_llvm`'s own `cc_wrapper.sh.tpl` uses with
    # `%{toolchain_path_prefix}` resolved from `_pkg_path_from_label`.
    #
    # Two invocation paths reach the shim with different `$0` shapes. Compile /
    # link routed through cc_wrapper.sh: `$0` is the absolute path
    # `${toolchain_path_prefix}bin/<tool>` that cc_wrapper.sh execs (where
    # `toolchain_path_prefix` was normalized to absolute by cc_wrapper.sh's own
    # resolution block). Direct Bazel `tool_paths` invocations (ar / nm / ld /
    # objcopy / etc., bypassing cc_wrapper.sh): `$0` is the relative execroot
    # path `external/<adapter>/bin/<tool>`. Bazel runs actions with CWD =
    # execroot, so `$PWD/$0` is the absolute path. The shim handles both via a
    # `case "$0" in /*)` branch.
    #
    # `readlink -f "$0"` is NOT used because Bazel's `linux-sandbox`
    # materializes cross-repo inputs as file copies (not symlinks), so an
    # `rctx.symlink` bridge from `@toolchains_llvm++llvm+llvm_toolchain//
    # bin/<tool>` to this adapter's `bin/<tool>` appears as a regular file at
    # sandbox time and `readlink -f` returns the toolchains_llvm path where
    # `<tool>.real` does not exist. The `$0`-strip approach reaches the
    # adapter's own `bin/` regardless of which symlink-or-copy invoked the shim.
    #
    # `exec -a "$0"` (NOT `basename "$0"`) preserves the execroot-relative path
    # argv[0] Bazel hands to the shim. Bazel passes `-no-canonical-prefixes` on
    # every CppCompile, which disables clang's `/proc/self/exe`-based
    # self-location: clang reads argv[0] verbatim to compute `InstalledDir` and,
    # from there, the resource dir holding `stddef.h` / `stdarg.h` /
    # `immintrin.h`. A bare `clang` (after `basename`) makes `InstalledDir`
    # empty, the resource dir relative, and the headers unresolvable against the
    # action CWD. The full-path argv[0] routes auto-detection through this
    # adapter's own `bin/` and finds `lib/clang/<ver>/include/` next door.
    # Multi-personality dispatch (`clang` vs `clang++` vs `clang-cpp` all
    # hardlink to the same driver) still works because the driver keys on
    # `basename(argv[0])`.
    shim_result = rctx.execute([
        "sh",
        "-c",
        _SHIM_INSTALL_SCRIPT.format(
            bin_dir = str(rctx.path("bin")),
            adapter_repo = rctx.name,
        ),
    ])
    if shim_result.return_code != 0:
        fail("shim installation failed (%d): %s\n%s" % (
            shim_result.return_code,
            shim_result.stderr,
            shim_result.stdout,
        ))

    # Render a custom BUILD.bazel matching `toolchains_llvm`'s expected
    # filegroup names. Debian's clang resource dir is the full patch version
    # (`lib/clang/14.0.6`) below LLVM 16 and the major only (`lib/clang/19`)
    # from 16 on, matching `toolchains_llvm`'s own substitution; pick the shape
    # from the major so this adapter spans both.
    resource_dir = (
        rctx.attr.llvm_version if int(llvm_major) < 16 else llvm_major
    )
    rctx.file(
        "BUILD.bazel",
        _BUILD_TEMPLATE.format(LLVM_VERSION = resource_dir),
    )

# Shell script writing one shim per ELF binary in bin/. Detects ELFs via the
# magic bytes (`\x7fELF`); preserves bin/<tool> as the shim while moving the
# real binary aside to bin/<tool>.real. Skips already-wrapped tools (idempotent
# in case Bazel re-runs the repo rule). buildifier: disable=external-path
_SHIM_INSTALL_SCRIPT = """\
set -eu
cd "{bin_dir}"
# Bash shebang (not /bin/sh): `exec -a` is a bash builtin; dash (Debian's
# default /bin/sh) doesn't support it. `exec -a "$0"` passes argv[0]
# through unchanged so clang's argv[0]-based resource-dir auto-detection
# (active under Bazel's `-no-canonical-prefixes`) resolves through this
# adapter's `bin/` and finds `lib/clang/<ver>/include/`; multi-driver
# dispatch (clang / clang++ / clang-cpp hardlinks) still works because
# the driver keys on `basename(argv[0])`.
#
# `exec_root` is derived from `$0` (absolute when invoked by cc_wrapper.sh,
# relative when invoked directly by Bazel from execroot CWD), then the
# adapter `bin/` / `lib/` are reached via the canonical adapter repo name
# baked in at adapter-build time. This bypasses `readlink -f "$0"` (which
# does not follow Bazel sandbox's materialized-copy of cross-repo symlinks).
shim_body='#!/bin/bash
case "$0" in
  /*) shim_path="$0" ;;
  *)  shim_path="${{PWD}}/$0" ;;
esac
exec_root="${{shim_path%%/external/*}}"
adapter_bin="${{exec_root}}/external/{adapter_repo}/bin"
adapter_lib="${{exec_root}}/external/{adapter_repo}/lib"
export LD_LIBRARY_PATH="${{adapter_lib}}${{LD_LIBRARY_PATH:+:${{LD_LIBRARY_PATH}}}}"
exec -a "$0" "${{adapter_bin}}/$(basename "$0").real" "$@"'
for f in *; do
    case "$f" in
        *.real) continue ;;
    esac
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    # ELF magic: first four bytes are 0x7f 'E' 'L' 'F'
    magic=$(head -c 4 -- "$f" 2>/dev/null | od -An -c | tr -d ' ')
    case "$magic" in
        177ELF*) ;;
        *) continue ;;
    esac
    mv -- "$f" "$f.real"
    printf '%s\\n' "$shim_body" > "$f"
    chmod 0755 "$f"
done
"""

_BUILD_TEMPLATE = """\
package(default_visibility = ["//visibility:public"])

# Canonical-layout BUILD for the Debian-sourced LLVM toolchain. Mirrors the
# filegroup names in `@toolchains_llvm//toolchain:BUILD.llvm_repo.tpl` so
# `llvm.toolchain_root(label = ...)` consumes this hub correctly. Diffs vs the
# upstream template:
#   - libc++-specific filegroup srcs (`include/c++/v1`, `lib/libc++*.a`,
#     `lib/libunwind.a`) are kept as globs with `allow_empty = True`. Our
#     stdlib = stdc++ sources libstdc++ from `@libc_sysroot`'s sysroot; Debian
#     llvm-14 doesn't bundle libc++.
#   - `:cxx_builtin_include` keeps only `lib/clang/<ver>/include` (clang's
#     resource headers like `immintrin.h`); libstdc++ headers come via the
#     cc_toolchain's `--sysroot=` flag.
#   - `:lib` drops the `lib/clang/<ver>/lib` reference (compiler-rt builtins);
#     Debian doesn't ship the directory at that path, and stdlib = stdc++ uses
#     libgcc.a from `@libc_sysroot`'s `libgcc-12-dev` for the builtins clang
#     would otherwise pull from compiler-rt.

exports_files(glob(
    [
        "bin/*",
        "lib/**",
        "include/**",
    ],
    allow_empty = True,
))

filegroup(
    name = "clang",
    srcs = [
        "bin/clang",
        "bin/clang.real",
        "bin/clang++",
        "bin/clang++.real",
        "bin/clang-cpp",
        "bin/clang-cpp.real",
    ],
)

filegroup(
    name = "ld",
    srcs = [
        "bin/ld.lld",
        "bin/ld.lld.real",
    ] + glob(
        [
            "bin/ld64.lld",
            "bin/ld64.lld.real",
            "bin/wasm-ld",
            "bin/wasm-ld.real",
        ],
        allow_empty = True,
    ),
)

filegroup(
    name = "include",
    srcs = glob(
        [
            "include/**/c++/**",
            "lib/clang/*/include/**",
        ],
        allow_empty = True,
    ),
)

filegroup(
    name = "all_includes",
    srcs = glob(["include/**"], allow_empty = True),
)

filegroup(
    name = "cxx_builtin_include",
    # Globbed to actual files: a directory src isn't expanded by Bazel under
    # `--incompatible_disallow_empty_glob`-strict configs. The upstream
    # BUILD.llvm_repo.tpl uses `srcs = ["lib/clang/<ver>/include"]` (a dir
    # ref) which works in their canonical-tarball setup but here leaves
    # `:cxx_builtin_include_files-<suffix>` (in `@llvm_toolchain`) empty,
    # so compile actions can't find `stddef.h` / `stdarg.h` / `immintrin.h`
    # in their sandbox.
    srcs = glob(["lib/clang/{LLVM_VERSION}/include/**"]),
)

filegroup(
    name = "extra_config_site",
    srcs = glob(["include/*/c++/v1/__config_site"], allow_empty = True),
)

filegroup(
    name = "bin",
    srcs = glob(["bin/**"]),
)

filegroup(
    name = "lib",
    srcs = glob(
        [
            # Debian-shipped runtime libs that clang / llvm-* tools need at
            # exec time (libLLVM-14.so.1, libclang-cpp.so.14, libedit.so.2,
            # libxml2.so.2, libtinfo.so.6, libz.so.1, libgcc_s.so.1, ...).
            # Pulled in here so `toolchains_llvm`'s `compiler-files-<suffix>`
            # / `linker-files-<suffix>` filegroups make them available in
            # every action sandbox. Without this, ld.so fails with `cannot
            # open shared object file: No such file or directory` even though
            # the wrapper exports LD_LIBRARY_PATH pointing at this `lib/`.
            "lib/**/*.so*",
            # libc++-specific libs (upstream LLVM tarball ships them; Debian
            # doesn't bundle libc++); empty here since stdlib = stdc++.
            "lib/**/libc++*.a",
            "lib/**/libunwind.a",
        ],
        allow_empty = True,
    ),
)

# `:lib_legacy` mirrors `:lib`. `toolchains_llvm`'s `configure.bzl:641` picks
# `lib_label` based on `bazel_features.rules.merkle_cache_v2`: when False
# (Bazel < 8 or merkle-cache disabled), `linker-components-<suffix>` references
# `:lib_legacy` instead. The upstream default `:lib_legacy` is
# `glob(["lib/clang/<ver>/lib/**", ...])` which contains zero runtime `.so`
# files (the relocatable LLVM tarball uses `RPATH=$ORIGIN/../lib` and doesn't
# need them in the sandbox); keeping the same broad glob here means the link
# sandbox carries Debian's runtime libs regardless of which feature flag is
# active. See REPORT-Postgres_LLVM_JIT.md (research) for the chain.
filegroup(
    name = "lib_legacy",
    srcs = glob(
        [
            "lib/**/*.so*",
            "lib/**/libc++*.a",
            "lib/**/libunwind.a",
            "lib/clang/{LLVM_VERSION}/lib/**",
        ],
        allow_empty = True,
    ),
)

filegroup(name = "ar", srcs = ["bin/llvm-ar", "bin/llvm-ar.real"])

filegroup(name = "as", srcs = ["bin/clang", "bin/clang.real", "bin/llvm-as", "bin/llvm-as.real"])

filegroup(name = "nm", srcs = ["bin/llvm-nm", "bin/llvm-nm.real"])

filegroup(name = "objcopy", srcs = ["bin/llvm-objcopy", "bin/llvm-objcopy.real"])

filegroup(name = "objdump", srcs = ["bin/llvm-objdump", "bin/llvm-objdump.real"])

filegroup(name = "profdata", srcs = ["bin/llvm-profdata", "bin/llvm-profdata.real"])

filegroup(name = "dwp", srcs = ["bin/llvm-dwp", "bin/llvm-dwp.real"])

filegroup(name = "ranlib", srcs = ["bin/llvm-ranlib", "bin/llvm-ranlib.real"])

filegroup(name = "readelf", srcs = ["bin/llvm-readelf", "bin/llvm-readelf.real"])

filegroup(name = "strip", srcs = ["bin/llvm-strip", "bin/llvm-strip.real"])

filegroup(name = "symbolizer", srcs = ["bin/llvm-symbolizer", "bin/llvm-symbolizer.real"])

filegroup(name = "clang-tidy", srcs = ["bin/clang-tidy", "bin/clang-tidy.real"])

filegroup(name = "clang-format", srcs = ["bin/clang-format", "bin/clang-format.real"])

filegroup(
    name = "git-clang-format",
    srcs = glob(
        ["bin/git-clang-format", "bin/git-clang-format.real"],
        allow_empty = True,
    ),
)

filegroup(
    name = "libclang",
    srcs = glob(
        [
            "lib/libclang.so",
            "lib/libclang.dylib",
        ],
        allow_empty = True,
    ),
)
"""

cc_toolchain_layout = repository_rule(
    implementation = _impl,
    attrs = {
        "arch": attr.string(
            mandatory = True,
            doc = "Debian arch (`amd64`, `arm64`) this adapter is " +
                  "instantiated for. Its Debian multiarch tuple is derived " +
                  "via `@sysroots//apt:layout.bzl` to locate the multiarch " +
                  "lib path (`usr/lib/<tuple>/`) where libLLVM-14.so.1's " +
                  "transitive deps (libedit, libxml2, libffi, libtinfo, " +
                  "libz, libgssapi-krb5, ...) live; those libs are " +
                  "hardlinked into the adapter's `lib/` so they resolve via " +
                  "the wrapper's `LD_LIBRARY_PATH=${toolchain_path_prefix}lib`.",
        ),
        "llvm_version": attr.string(
            mandatory = True,
            doc = "LLVM version string (e.g. `14.0.6`). Substituted into the " +
                  "`{LLVM_VERSION}` placeholder in the BUILD template's " +
                  "`lib/clang/<version>` srcs.",
        ),
        "sysroot": attr.label(
            mandatory = True,
            doc = "Label anchoring a file inside the per-arch sysroot at " +
                  "`@llvm_sysroot//debian/12/<arch>` (the BUILD.bazel of " +
                  "that package works). `dirname` of its `rctx.path` is " +
                  "treated as the per-arch sysroot root.",
        ),
    },
)
