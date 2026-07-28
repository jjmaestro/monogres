"""
Build an EXEC-arch binary from a Rust crate, offline.

The counterpart to `pgrx.bzl` for build tools rather than extensions: no
Postgres, no per-extension sysroot, no install tree, just `cargo build` against
a vendor tree from the shared crate pool. It exists for the pgrx SQL generator,
which reads a link section out of a built cdylib and so has to be a binary that
runs during the build, not an extension artifact.

EXEC in Bazel's sense: the arch of the machine the action runs on. That is the
arch cargo calls the HOST (cargo's "target" and Bazel's TARGET do agree), and
the one autoconf confusingly calls the BUILD. Only the buildtime libc sysroot is
staged, since that is what rustc links this binary against: it links through a C
driver, and the hermetic sandbox carries no system libc.
"""

load("@platform_debian//:versions.bzl", "RELEASE")
load("//toolchains/llvm_sysroot:llvm_version.bzl", "LLVM_MAJOR")

# Shared with `ext_build`: the action-time script that extracts a sysroot tar,
# patches the perl Config files in it and symlinks the clang wrapper inside the
# extracted tree, plus the sibling lib it sources and the wrapper it plants.
_SYSROOT_SETUP_SCRIPT = "@monogres//monoext/private/base:sysroot_setup.sh"
_SYSROOT_LIB_SCRIPT = "@monogres//monoext/private/base:sysroot_lib.sh"
_SYSROOT_CLANG_WRAPPER = "@monogres//toolchains/libc_sysroot:active_clang_wrapper"

# The buildtime sysroot for the active Debian release: the C runtime rustc links
# the binary against.
_LIBC_SYSROOT_TAR = "@libc_sysroot//debian/{}:sysroot_tar".format(RELEASE.version)

# @llvm_sysroot, staged for its EXEC-arch `usr/lib/<multiarch>`: that is where
# `libz.so.1` lives, which rustc NEEDs and @libc_sysroot does not carry. Same
# dir the PGXS path puts on its build tools' `LD_LIBRARY_PATH`.
_LLVM_SYSROOT = "@llvm_sysroot//debian/{}:sysroot".format(RELEASE.version)

_CARGO = "@monogres//toolchains/rust:cargo"
_RUST_FILES = "@monogres//toolchains/rust:files"

_TOOLCHAINS = [
    "@bazel_tools//tools/cpp:current_cc_toolchain",
    "@bsd_tar_toolchains//:resolved_toolchain",
    "@monogres//toolchains/libc_sysroot:libc_sysroot_dir",
    "@monogres//toolchains/libc_sysroot:libc_sysroot_exec_dir",
    "@monogres//toolchains/llvm_sysroot:llvm_sysroot_exec_dir",
]

_CMD = """
set -eu

export EXT_BUILD_ROOT="$$PWD"

CARGO="$$EXT_BUILD_ROOT/$(execpath {cargo})"
RUST_PREFIX="$$(dirname "$$(dirname "$$CARGO")")"

# cargo runs `rustc` (and any dependency's `rustfmt`) by name out of its own
# prefix.
export PATH="$$RUST_PREFIX/bin:$$PATH"

# rustc infers its sysroot from its own location, and gets it wrong here: it
# answers with the repo root rather than the prefix `bin/rustc` sits in, then
# fails to find `core`. Name it instead. RUSTC_WRAPPER is the hook cargo runs
# EVERY unit through, host and target alike, which `RUSTFLAGS` is not: with
# `--target` given, cargo withholds those from host units.
rustc_wrapper="$$EXT_BUILD_ROOT/rustc_wrapper"
printf '#!/bin/sh\\nrustc="$$1"; shift\\nexec "$$rustc" --sysroot "%s" "$$@"\\n' \
    "$$RUST_PREFIX" > "$$rustc_wrapper"
chmod +x "$$rustc_wrapper"
export RUSTC_WRAPPER="$$rustc_wrapper"

# rustc and cargo are dynamically linked, and the sandbox has no system libc for
# them, so point them at the EXEC-arch sysroot the same way the extension builds
# point their build tools.
libc_sysroot_exec="$$EXT_BUILD_ROOT/$(LIBC_SYSROOT_EXEC_DIR)"
llvm_sysroot_exec="$$EXT_BUILD_ROOT/$(LLVM_SYSROOT_EXEC_DIR)"
exec_multiarch="$(LIBC_SYSROOT_EXEC_MULTIARCH)"
ld_library_path=(
    "$$libc_sysroot_exec/lib/$$exec_multiarch"
    "$$libc_sysroot_exec/usr/lib/$$exec_multiarch"
    "$$llvm_sysroot_exec/usr/lib/$$exec_multiarch"
)
export LD_LIBRARY_PATH
LD_LIBRARY_PATH="$$(IFS=:; echo "$${{ld_library_path[*]}}")"

# The sysroot the binary is linked against, extracted by the shared setup
# script (crt files, libc, the linker's search root).
sysroot_dir=$$(sh \
    "$$EXT_BUILD_ROOT/$(execpath {setup})" \
    "$$EXT_BUILD_ROOT/$(execpath {sysroot_tar})" \
    "$$EXT_BUILD_ROOT/$(execpath {wrapper})" \
    "{tar_cmd}" \
    "{llvm_major}")

# rustc links through a C driver; wrap it so the sysroot flags ride every link
# whether cargo classes the unit as host (its word for the EXEC arch) or target.
linker="$$EXT_BUILD_ROOT/rust_linker"
printf '#!/bin/sh\\nexec "%s" --sysroot="%s" -L"%s/usr/lib/%s" "$$@"\\n' \
    "$$EXT_BUILD_ROOT/$(CC)" \
    "$$sysroot_dir" \
    "$$sysroot_dir" \
    "$(LIBC_SYSROOT_MULTIARCH)" > "$$linker"
chmod +x "$$linker"
export RUSTFLAGS="-C linker=$$linker"

# cargo writes into the crate root, and the sources are read-only inputs.
src="$$EXT_BUILD_ROOT/crate"
cp -RL "$$(dirname "$$EXT_BUILD_ROOT/$(execpath {manifest})")" "$$src"
chmod -R u+w "$$src"

# The dependency closure as a cargo directory source, so `--offline` resolves
# every crate locally and `--locked` holds it to the committed `Cargo.lock`.
vendor="$$EXT_BUILD_ROOT/vendor"
mkdir -p "$$vendor"
{tar_cmd} -xf "$$EXT_BUILD_ROOT/$(execpath {vendor_tar})" -C "$$vendor"

export CARGO_HOME="$$EXT_BUILD_ROOT/cargo_home"
mkdir -p "$$CARGO_HOME"
{{
    echo "[source.crates-io]"
    echo "replace-with = \\"vendor\\""
    echo
    echo "[source.vendor]"
    echo "directory = \\"$$vendor\\""
}} > "$$CARGO_HOME/config.toml"

export CARGO_NET_OFFLINE=true
export CARGO_TARGET_DIR="$$EXT_BUILD_ROOT/cargo_target"


( cd "$$src" && "$$CARGO" build --offline --locked --release )

cp "$$CARGO_TARGET_DIR/release/{bin}" "$$EXT_BUILD_ROOT/{out}"
"""

def cargo_bin(name, manifest, srcs, vendor_tar, bin = None, visibility = None):
    """Emits a genrule building one Rust binary for the EXEC arch.

    Args:
        name: Target name; the output is a binary of the same name.
        manifest: Label of the crate's `Cargo.toml`. Its directory is the crate
            root, which is how the action finds the sources.
        srcs: Label of the rest of the crate (`src/**` and the `Cargo.lock`
            `--locked` holds the build to).
        vendor_tar: Label of the `cargo_vendor` tar covering the crate's whole
            dependency closure.
        bin: Name of the binary cargo produces, if it differs from `name`.
        visibility: Target visibility.
    """
    bin = bin or name

    # Under the target's own directory: a genrule may not declare an output
    # named after itself, and cargo's binary name is not ours to choose.
    out = "%s/%s" % (name, bin)

    native.genrule(
        name = name,
        srcs = [
            manifest,
            srcs,
            vendor_tar,
            _LIBC_SYSROOT_TAR,
            _LLVM_SYSROOT,
            _SYSROOT_CLANG_WRAPPER,
            _SYSROOT_SETUP_SCRIPT,
            _SYSROOT_LIB_SCRIPT,
        ],
        tools = [_CARGO, _RUST_FILES],
        outs = [out],
        cmd = _CMD.format(
            bin = bin,
            cargo = _CARGO,
            llvm_major = LLVM_MAJOR,
            manifest = manifest,
            out = "$(location %s)" % out,
            setup = _SYSROOT_SETUP_SCRIPT,
            sysroot_tar = _LIBC_SYSROOT_TAR,
            tar_cmd = "$(BSDTAR_BIN)",
            vendor_tar = vendor_tar,
            wrapper = _SYSROOT_CLANG_WRAPPER,
        ),
        executable = True,
        toolchains = _TOOLCHAINS,
        visibility = visibility,
    )
