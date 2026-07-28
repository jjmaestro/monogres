"""
Rule to build pgrx (Rust) Postgres extensions from source.

Internal to monoext; invoked from generated `@{name}_ext//...` BUILD files when
an extension declares `metadata.build_system == "pgrx"`.

Reuses the shared genrule engine (`ext_build`) exactly as the PGXS and CMake
paths do: same sysroot layering, same DESTDIR-relocate, same `<base_v>.tar`
artifact contract. What differs is the compiler. A pgrx extension is a Rust
crate that links against Postgres's server headers, so `compile_extension` runs
`cargo build` instead of `make`, and the two things cargo normally reaches the
network for are supplied as build inputs:

- the dependency closure, as a cargo directory source tarred by `cargo_vendor`
  out of the shared crate pool, plus the catalog `Cargo.lock` that pool was
  built from. `--offline --locked` then makes cargo re-derive the lock from the
  manifest and fail if it disagrees, so a build can only ever use the crates the
  lock pins.
- the Rust toolchain itself, from `//toolchains/rust`.

The extension SQL is generated WITHOUT running the extension: pgrx >= 0.18
records its SQL entity graph in a `.pgrxsc` link section of the cdylib, and
`sql_generator` reads that section statically. `cargo pgrx schema`, the upstream
route, instead dlopens the freshly built library and runs code out of it, which
neither a sandbox nor a cross-compile can do.

Nothing here executes a TARGET-arch binary, so this cross-compiles:
`pgrx-pg-sys` is TOLD the `pg_config` answers through `PGRX_PG_CONFIG_AS_ENV`
rather than running the binary, and the SQL is read out of the cdylib as data
rather than by running it. Verified against arm64 from an amd64 host, cdylib and
SQL both.

Cross is what the split-looking parts below are for, and each split collapses to
one case natively: the rustc sysroot (the TARGET arch's `rust-std` has to be
borrowed into the EXEC arch's prefix, since rustup ships one per prefix), the
linker (a build script is linked for the arch it RUNS on), and `CC` (same, for
any C a dependency compiles). cargo calls the EXEC side HOST; its "target" and
Bazel's TARGET agree.
"""

load(
    "//monoext/private/ext/build:build.bzl",
    "ext_build",
)
load(
    "//monoext/private/ext/build:build_args.bzl",
    "PGRX_ARG_SUBST",
)

# The hermetic Rust toolchain: `cargo` alone as a single-file label (so its
# `execpath` locates the prefix) plus the whole tree, since cargo runs `rustc`,
# `rustfmt` and the `rust-std` libraries out of it. Both ride `tools`: cargo
# runs as part of the action, so it is the EXEC arch that selects them.
_CARGO = "@monogres//toolchains/rust:cargo"
_RUST_FILES = "@monogres//toolchains/rust:files"

# The TARGET arch's copy of the same tree, for its `lib/rustlib/<triple>`:
# rustup ships one `rust-std` per prefix, for that prefix's own arch, so the
# EXEC tree above cannot compile TARGET code by itself. These ride `srcs`, which
# is what makes them resolve in the TARGET configuration. Inert (the same files
# as the EXEC pair) whenever the two arches agree.
_RUST_TARGET_CARGO = "@monogres//toolchains/rust:target_cargo"
_RUST_TARGET_FILES = "@monogres//toolchains/rust:target_files"

# pgrx `compile_extension`: stage the vendor tree and the lock, point cargo at
# them, build the cdylib, then install it next to a statically generated SQL
# file and the substituted control file.
_COMPILE_EXTENSION = """
        compile_extension() {{
            local cc="$$1"; shift
            local pgrx_src="$$1"; shift
            local sysroot_dir="$$1"; shift
            local pg_sysroot_dir="$$1"; shift
            local installdir="$$1"; shift

            # Remap the declared baked paths in the sysroot's `*-config` scripts
            # so they resolve inside the extracted sysroot. Empty (no calls) for
            # extensions that declare no `metadata.remap_paths`.
            {remap_paths}

            # cargo writes into the crate root (`Cargo.lock`, `target/`) and the
            # source is a read-only Bazel tree artifact, so build from a copy,
            # as the PGXS path does. `-L` because the tree arrives as symlinks.
            local src="$$EXT_BUILD_ROOT/pgrx_src_copy"
            cp -raL "$$pgrx_src" "$$src"
            chmod -R u+w "$$src"

            # Where the extension crate itself lives. `$$src` for the usual
            # single-crate source tree; a subdirectory when the tree is a cargo
            # WORKSPACE, whose root has to stay `$$src` so the crate's path
            # dependencies and the workspace `[profile.release]` still resolve.
            # cargo walks up from the cwd to find that root on its own, which is
            # also what running it from the crate dir makes `--lib` unambiguous.
            local crate_dir="$$src{crate_dir}"

            # Shared sysroot compile environment: sets the `target_multiarch`,
            # `exec_multiarch`, `cflags`, `ldflags` globals and exports
            # PKG_CONFIG_*. See `setup_compile_env` in the shared engine.
            setup_compile_env "$$sysroot_dir" "$$pg_sysroot_dir"

            local abs_pg_install_dir="$$EXT_BUILD_ROOT/$(PG_INSTALL_DIR)"
            local pgxs_installdir
            pgxs_installdir="$$(make_pgxs_installdir "$$installdir")"

            # pgrx requires a `<extname>.control` at the crate root and names
            # every installed artifact after it, so the control file is where
            # the extension's identity comes from here too.
            local control extname
            control="$$(echo "$$crate_dir"/*.control)"
            extname="$$(basename "$$control" .control)"

            # The dependency closure as a cargo directory source. Built once per
            # (extension, version) and extracted by each PG major, since a major
            # is only a cargo feature and the closure is the same for all three.
            local vendor="$$EXT_BUILD_ROOT/vendor"
            mkdir -p "$$vendor"
            {tar_cmd} -xf "$$EXT_BUILD_ROOT/$(execpath {vendor_tar})" -C "$$vendor"

            # The lock the crate pool was built from. Copied over whatever the
            # source archive ships so `--locked` compares the manifest against
            # the same lock the vendor tree was fetched by.
            cp -L "$$EXT_BUILD_ROOT/$(execpath {cargo_lock})" "$$src/Cargo.lock"
            chmod u+w "$$src/Cargo.lock"

            # Source replacement: resolve `crates-io` from the vendor tree.
            # Written to a private CARGO_HOME rather than the source tree, which
            # keeps the extension's own `.cargo/` (if it ships one) untouched.
            export CARGO_HOME="$$EXT_BUILD_ROOT/cargo_home"
            mkdir -p "$$CARGO_HOME"
            {{
                echo "[source.crates-io]"
                echo "replace-with = \\"vendor\\""
                echo
                echo "[source.vendor]"
                echo "directory = \\"$$vendor\\""
            }} > "$$CARGO_HOME/config.toml"

            # One more replacement per git source the lock names, resolving out
            # of that same tree: cargo would otherwise clone the repository,
            # which an offline sandbox cannot do. Empty (no lines) for a closure
            # that is entirely crates.io, which is the common case.
            {git_sources}

            # Files a dependency's build script would otherwise download for
            # itself, which this sandbox cannot do and nothing would pin. Staged
            # at the paths the catalog declares, with each declared variable
            # pointing the fetching step at the tree. Writable, since a build
            # script that treats it as a cache unpacks and builds in place.
            {build_data}

            # cargo drives `rustc` and `rustfmt` (pgrx-pg-sys formats the
            # bindings it generates) out of its own prefix, by name off PATH.
            #
            # `make` joins them because a `-sys` crate that vendors a C library
            # builds it the way its upstream does, and looks the tool up by name
            # with no env var to redirect it. The same hermetic make the PGXS
            # path drives, so a C library built here and one built there are
            # built by the same tool.
            local rust_prefix
            rust_prefix="$$(dirname "$$(dirname "$$CARGO")")"
            export PATH="$$rust_prefix/bin:$$(dirname "$$EXT_BUILD_ROOT/$(MAKE)"):$$PATH"

            # Rust spells the same arch as Debian's multiarch tuple with a
            # vendor field: `x86_64-linux-gnu` -> `x86_64-unknown-linux-gnu`.
            local rust_target="$${{target_multiarch%%-*}}-unknown-linux-gnu"
            local rust_host="$${{exec_multiarch%%-*}}-unknown-linux-gnu"

            # Cross-compiling needs the TARGET arch's `rust-std` next to the
            # EXEC arch's compiler, and rustup ships one `rust-std` per prefix,
            # so neither tree has both. Build a prefix that does: the EXEC one,
            # with the TARGET tree's `lib/rustlib/<triple>` linked in beside its
            # own. Symlinks, since each tree is a couple of hundred megabytes.
            # Native builds just use the EXEC prefix as it comes.
            local rust_sysroot="$$rust_prefix"
            if [ "$$rust_target" != "$$rust_host" ]; then
                local target_rust_prefix entry
                target_rust_prefix="$$EXT_BUILD_ROOT/$(execpath {target_cargo})"
                target_rust_prefix="$$(dirname "$$(dirname "$$target_rust_prefix")")"

                rust_sysroot="$$EXT_BUILD_ROOT/rust_sysroot"
                mkdir -p "$$rust_sysroot/lib/rustlib"

                # `case` rather than `[ ... ] && continue`: a false test as the
                # last command of an iteration would trip the ERR trap.
                for entry in "$$rust_prefix"/*; do
                    case "$$(basename "$$entry")" in
                        lib) ;;
                        *) ln -sfn "$$entry" "$$rust_sysroot/" ;;
                    esac
                done
                for entry in "$$rust_prefix"/lib/*; do
                    case "$$(basename "$$entry")" in
                        rustlib) ;;
                        *) ln -sfn "$$entry" "$$rust_sysroot/lib/" ;;
                    esac
                done
                for entry in "$$rust_prefix"/lib/rustlib/*; do
                    ln -sfn "$$entry" "$$rust_sysroot/lib/rustlib/"
                done

                ln -sfn "$$target_rust_prefix/lib/rustlib/$$rust_target" \
                    "$$rust_sysroot/lib/rustlib/$$rust_target"
            fi

            # rustc infers its sysroot from its own location, and gets it wrong
            # here: it answers with the repo root rather than the prefix
            # `bin/rustc` sits in, then fails to find `core`. Name it instead.
            # RUSTC_WRAPPER is the hook cargo runs EVERY unit through, host and
            # target alike, which `RUSTFLAGS` is not: with `--target` given,
            # cargo withholds those from host units.
            local rustc_wrapper="$$EXT_BUILD_ROOT/rustc_wrapper"
            printf '#!/bin/sh\\nrustc="$$1"; shift\\nexec "$$rustc" --sysroot "%s" "$$@"\\n' \
                "$$rust_sysroot" > "$$rustc_wrapper"
            chmod +x "$$rustc_wrapper"
            export RUSTC_WRAPPER="$$rustc_wrapper"

            # Where the EXEC-arch tools find their NEEDED libs: the sandbox
            # chroot has no system `/lib`. The shared EXEC group from
            # `setup_compile_env`, plus @llvm_sysroot's, which is what carries
            # `libz.so.1` (rustc) and `libLLVM` (the clang the linker wraps).
            local llvm_sysroot_exec
            llvm_sysroot_exec="$$EXT_BUILD_ROOT/$(LLVM_SYSROOT_EXEC_DIR)"
            local ld_library_path=(
                "$${{ldpath_exec[@]}}"
                "$$llvm_sysroot_exec/lib/$$exec_multiarch"
                "$$llvm_sysroot_exec/usr/lib/$$exec_multiarch"
                "$$llvm_sysroot_exec/usr/lib/llvm-{llvm_major}/lib"
                "$${{ldpath_target[@]}}"
            )
            export LD_LIBRARY_PATH
            LD_LIBRARY_PATH="$$(IFS=:; echo "$${{ld_library_path[*]}}")"

            # bindgen, in pgrx-pg-sys's build script, dlopens libclang and then
            # preprocesses Postgres's server headers with it, so it needs both
            # the library and the same sysroot include path the C compiles get.
            export LIBCLANG_PATH="$$EXT_BUILD_ROOT/$(LLVM_SYSROOT_EXEC_DIR)/usr/lib/llvm-{llvm_major}/lib"
            export BINDGEN_EXTRA_CLANG_ARGS="$${{cflags[*]}}"

            # EXEC-arch compile / link flags, for the units cargo builds to run
            # during the build rather than to ship. The TARGET sysroot is the
            # extension's own; the EXEC one is @libc_sysroot's, which is where
            # this action's own tools already come from.
            local libc_sysroot_exec
            libc_sysroot_exec="$$EXT_BUILD_ROOT/$(LIBC_SYSROOT_EXEC_DIR)"
            local host_cflags=(
                "--target=$$exec_multiarch"
                "--sysroot=$$libc_sysroot_exec"
                "-idirafter $$libc_sysroot_exec/usr/include"
                "-idirafter $$libc_sysroot_exec/usr/include/$$exec_multiarch"
            )
            local host_ldflags=(
                "--target=$$exec_multiarch"
                "--sysroot=$$libc_sysroot_exec"
                "-Wl,--sysroot=$$libc_sysroot_exec"
                "-L$$libc_sysroot_exec/usr/lib/$$exec_multiarch"
            )

            # The `cc` crate, for any C a dependency compiles. It archives what
            # it builds, and looks `ar` up on PATH, which the sandbox has no
            # system copy of; `$(AR)` is the cc toolchain's own.
            #
            # `HOST_*` outrank `CC` / `CFLAGS` for cc-rs's host units, so the
            # plain pair stays TARGET-flavoured and build scripts still get
            # their own arch. Both pairs are the same thing on a native build.
            export CC="$$cc"
            export CFLAGS="$${{cflags[*]}}"
            export HOST_CC="$$cc"
            export HOST_CFLAGS="$${{host_cflags[*]}}"
            export AR="$$EXT_BUILD_ROOT/$(AR)"

            # How pgrx-pg-sys finds the Postgres to build against. pgrx will
            # happily RUN a `pg_config` (`PGRX_PG_CONFIG_PATH`), but that binary
            # is a TARGET-arch one, so an action could not execute it for a
            # foreign arch, and the rest of this engine deliberately never runs
            # it either (the PGXS path derives the same paths from
            # `$(PG_INSTALL_DIR)` for exactly that reason). `from_env` in
            # pgrx-pg-config takes the answers directly instead: with
            # `PGRX_PG_CONFIG_AS_ENV=true` every `PGRX_PG_CONFIG_<PROP>` becomes
            # the reply to `pg_config --<prop>`, and no binary is consulted.
            #
            # These are the six properties pgrx-bindgen asks for, and they are
            # what the real `pg_config` answers here: `--configure` is empty for
            # a meson build, `--cppflags` is just `-D_GNU_SOURCE`, and every
            # directory is the install prefix plus a fixed suffix. The names
            # carry a `-` where the property does (`--includedir-server`), which
            # is why these go through `env` below rather than `export`.
            local pg_config_env=(
                "PGRX_PG_CONFIG_AS_ENV=true"
                "PGRX_PG_CONFIG_VERSION=PostgreSQL {base_version}"
                "PGRX_PG_CONFIG_CONFIGURE="
                "PGRX_PG_CONFIG_CPPFLAGS=-D_GNU_SOURCE"
                "PGRX_PG_CONFIG_INCLUDEDIR-SERVER=$$abs_pg_install_dir/include/server"
                "PGRX_PG_CONFIG_PKGINCLUDEDIR=$$abs_pg_install_dir/include"
                "PGRX_PG_CONFIG_LIBDIR=$$abs_pg_install_dir/lib"
                "PGRX_PG_CONFIG_PKGLIBDIR=$$abs_pg_install_dir/lib"
                "PGRX_PG_CONFIG_SHAREDIR=$$abs_pg_install_dir/share"
            )

            # rustc links through a C driver, so the sysroot link flags have to
            # ride the linker rather than RUSTFLAGS: with `--target` given cargo
            # applies rustflags to target units only, and a build script (a HOST
            # unit, in cargo's words, so an EXEC-arch one in Bazel's) would link
            # without them.
            #
            # `--no-gc-sections` keeps the `.pgrxsc` section: nothing references
            # it, so on aarch64 Linux the linker drops it and the SQL comes out
            # empty. cargo-pgrx injects the same flag for itself (pgrx #2280,
            # the fix 0.18.1 exists for); driving cargo directly means injecting
            # it here, and unconditionally, since one flag beats an arch test.
            # One wrapper per arch. A build script is linked for the arch it
            # runs on, not the one being built for, and pointing both at the
            # TARGET flags is how you get an `is incompatible with
            # elf64-littleaarch64` out of an otherwise fine cross-compile.
            local linker="$$EXT_BUILD_ROOT/rust_linker"
            printf '#!/bin/sh\\nexec "%s" %s -Wl,--no-gc-sections "$$@"\\n' \
                "$$cc" "$${{ldflags[*]}}" > "$$linker"
            chmod +x "$$linker"

            local host_linker="$$EXT_BUILD_ROOT/rust_linker_host"
            printf '#!/bin/sh\\nexec "%s" %s -Wl,--no-gc-sections "$$@"\\n' \
                "$$cc" "$${{host_ldflags[*]}}" > "$$host_linker"
            chmod +x "$$host_linker"

            # `target.<triple>.linker`, per triple, which is how the wrapper
            # reaches cargo's host units (build scripts, proc macros) and not
            # just its target ones. Natively the two triples are one and the
            # same, so only the TARGET wrapper is ever named.
            local triple_env
            triple_env="$${{rust_target^^}}"
            export "CARGO_TARGET_$${{triple_env//-/_}}_LINKER=$$linker"

            if [ "$$rust_host" != "$$rust_target" ]; then
                triple_env="$${{rust_host^^}}"
                export "CARGO_TARGET_$${{triple_env//-/_}}_LINKER=$$host_linker"
            fi

            # Everything cargo would otherwise fetch is already staged, so a
            # network access here is a bug, not a fallback.
            export CARGO_NET_OFFLINE=true
            export CARGO_TARGET_DIR="$$EXT_BUILD_ROOT/cargo_target"

            local cargo_args=(
                "--offline"
                "--locked"
                "--release"
                "--lib"
                "--target" "$$rust_target"
                # A pgrx crate's `default` feature is one `pgNN`, picked for
                # whoever runs `cargo build` by hand; the build is for exactly
                # one major, so replace it rather than add to it.
                "--no-default-features"
                "--features" "pg{pg_major}"
                {build_args}
            )

            echo "# $$(date) - pgrx_build"
            echo "src: $$src"
            echo "crate_dir: $$crate_dir"
            echo "extname: $$extname"
            echo "rust_target: $$rust_target"
            echo "pg_config: $${{pg_config_env[*]}}"
            echo

            (
                cd "$$crate_dir" &&
                    env "$${{pg_config_env[@]}}" \
                        "$$CARGO" build "$${{cargo_args[@]}}"
            ) || return $$?

            local so="$$CARGO_TARGET_DIR/$$rust_target/release/lib$$extname.so"
            if [ ! -f "$$so" ]; then
                echo "pgrx: no cdylib at $$so" >&2
                return 1
            fi

            # The install layout `cargo pgrx package` produces, which is also
            # what PGXS `install` produces: the module under `pkglibdir` named
            # as the control file's `module_pathname` expects, the schema and
            # the control under `<sharedir>/extension`.
            mkdir -p "$$pgxs_installdir/lib" "$$pgxs_installdir/share/extension"
            cp "$$so" "$$pgxs_installdir/lib/$$extname.so"

            # `@CARGO_VERSION@` is pgrx's placeholder for the crate version;
            # cargo-pgrx substitutes it when it packages the control file.
            sed "s/@CARGO_VERSION@/{ext_version}/g" "$$control" \
                > "$$pgxs_installdir/share/extension/$$extname.control"

            # The extension SQL: generated off the cdylib, or taken from the
            # source when upstream ships it already generated.
            {install_sql}

            echo
            echo "Extension compiled OK"
        }}
"""

# The cargo config keys one source-replacement stanza carries, in the order
# `cargo vendor` writes them. A source names at most one of the three refs.
_GIT_SOURCE_KEYS = ("git", "branch", "tag", "rev")

# Continuation indent of the rendered stanzas, matching `compile_extension`.
_GIT_SOURCES_INDENT = 12

def _git_sources_config(git_sources):
    """Render shell appending `git_sources` to the cargo config.

    Args:
        git_sources: `{source: {key: value}}` from `pool.git_sources`.

    Returns:
        A `printf` call writing the stanzas, or `""` for no git sources.
    """
    if not git_sources:
        return ""

    lines = []

    for source in sorted(git_sources):
        entry = git_sources[source]

        lines.append("")
        lines.append('[source."%s"]' % source)
        lines += [
            '%s = "%s"' % (key, entry[key])
            for key in _GIT_SOURCE_KEYS
            if key in entry
        ]
        lines.append('replace-with = "vendor"')

    # One single-quoted argument per line, so nothing a URL or a branch name can
    # hold is read as shell.
    pad = " " * (_GIT_SOURCES_INDENT + 4)
    args = ["%s'%s'" % (pad, line) for line in lines]

    return "printf '%s\\n' \\\n{args} \\\n{pad}>> \"$$CARGO_HOME/config.toml\"".format(
        args = " \\\n".join(args),
        pad = pad,
    )

# Static SQL generation off the cdylib's `.pgrxsc` section: reads the file,
# never loads or runs it. What every pgrx >= 0.18 extension gets.
_GENERATE_SQL = """\
"$$PGRXSC_SQL" \\
                "$$so" \\
                "$$control" \\
                "$$extname" \\
                "{ext_version}" \\
                > "{dest}"\
"""

# The alternative: the SQL upstream generated at release time and committed,
# which is what its own `make install` installs. An extension that ships it
# needs no generator, and so no pgrx recent enough to have a `.pgrxsc` section
# at all.
#
# `chmod` because Bazel marks every file in an output tree executable, and the
# generated path writes a plain 0644 file.
_SHIPPED_SQL = """\
cp "$$src/{sql_source}" "{dest}"
            chmod 0644 "{dest}"\
"""

_SQL_DEST = "$$pgxs_installdir/share/extension/$$extname--{ext_version}.sql"

def _install_sql(sql_source, ext_version):
    """Render the shell that puts the extension SQL in the install tree.

    Args:
        sql_source: `metadata.sql_source`, a path below the source root, with
            `{version}` already resolved. Empty to generate the SQL instead.
        ext_version: The extension version, which names the installed file.

    Returns:
        Either the generator call or the copy.
    """
    dest = _SQL_DEST.format(ext_version = ext_version)

    if sql_source:
        return _SHIPPED_SQL.format(dest = dest, sql_source = sql_source)

    return _GENERATE_SQL.format(dest = dest, ext_version = ext_version)

# Where `compile_extension` stages `metadata.build_data`, and what the declared
# variables are resolved against.
_BUILD_DATA_DIR = "$$EXT_BUILD_ROOT/build_data"

def _build_data_config(build_data):
    """Render shell staging `build_data` and exporting what points at it.

    Args:
        build_data: `{"files": {path: label}, "env": {var: directory}}` from
            `metadata.build_data`, with the pool labels already resolved.

    Returns:
        Shell staging the files and exporting the variables, or `""` for an
        extension that declares no build data.
    """
    if not build_data:
        return ""

    files = build_data["files"]
    pad = " " * _GIT_SOURCES_INDENT
    lines = []

    for path in sorted(files):
        dest = '"%s/%s"' % (_BUILD_DATA_DIR, path)

        lines.append('mkdir -p "$$(dirname %s)"' % dest)
        lines.append('cp -L "$$EXT_BUILD_ROOT/$(execpath {})" {}'.format(
            files[path],
            dest,
        ))

    for var in sorted(build_data.get("env", {})):
        directory = build_data["env"][var]
        suffix = "" if directory == "." else "/" + directory

        lines.append('export {}="{}{}"'.format(var, _BUILD_DATA_DIR, suffix))

    return ("\n" + pad).join(lines)

# Prologue staging the two action-time binaries `compile_extension` runs by
# path: cargo (whose prefix also supplies `rustc` / `rustfmt`) and the SQL
# generator. Both run in the action itself and ride `tools`.
_PROLOGUE_EXTRA = """
        CARGO="$$EXT_BUILD_ROOT/$(execpath {cargo})"
        export CARGO
"""

# The generator half, left out for an extension that ships its own SQL: there is
# then no generator target to name, and none is built.
_PROLOGUE_SQL_GENERATOR = """
        PGRXSC_SQL="$$EXT_BUILD_ROOT/$(execpath {sql_generator})"
        export PGRXSC_SQL
"""

def pgrx_build(
        name,
        src,
        deps_buildtime,
        base_version,
        base_hub,
        base_sysroot_tar,
        prefix_distro,
        *,
        vendor_tar,
        cargo_lock,
        ext_version,
        sql_generator = None,
        sql_source = "",
        crate_dir = "",
        git_sources = {},
        build_data = {},
        build_args = [],
        remap_paths = {},
        debug = False):
    """Builds a pgrx (Rust) Postgres extension.

    Args:
        name (str): Bazel target name (the base version string).
        src (str): Label of the extension source tree, the source repo `:dir`.
        deps_buildtime (list[str]): At most one entry, the per-extension
            buildtime `:sysroot_tar` alias; empty falls back to `@libc_sysroot`.
        base_version (dict): `{name, version}` selecting the Postgres build. Its
            major also picks the crate's `pgNN` feature.
        base_hub (str): Base hub repo (e.g. `"@pg"`).
        base_sysroot_tar (str): Per-PG buildtime sysroot tar
            (`//_base/<base_v>:sysroot_tar`), layered via `-idirafter`/`-L`.
        prefix_distro (str): Install prefix (e.g. `"/postgres"`); base version
            appended internally.
        vendor_tar (str): Label of the `cargo_vendor` tar for this extension
            version, shared by every base version it builds for.
        cargo_lock (str): Label of the catalog `Cargo.lock` the crate pool was
            built from, copied into the source tree and enforced with
            `--locked`.
        ext_version (str): The extension version, i.e. the crate version pgrx
            spells `@CARGO_VERSION@`.
        sql_generator (str): Label of the binary that reads the cdylib's
            `.pgrxsc` section and writes the extension SQL. `None` when
            `sql_source` names the SQL instead, which is also when no generator
            is built for this extension's pgrx at all.
        sql_source (str): Path below the source root of the extension SQL as
            upstream ships it, from `metadata.sql_source`, with `{version}`
            already resolved. Set for an extension that generates its SQL at
            release time and commits it, which is then what its own `install`
            target installs; empty to generate it here instead.
        crate_dir (str): The extension crate's directory below the source root,
            from `metadata.crate_dir`. Empty (the default) means the source root
            IS the crate. Set it when the tree is a cargo workspace: the root
            stays the source root, so path dependencies and the workspace
            `[profile.release]` resolve, while cargo runs in the crate.
        git_sources (dict[str, dict[str, str]]): `{source: {key: value}}` from
            `pool.git_sources`, the cargo source replacement pointing every git
            dependency in the lock at the vendor tree. Empty for a closure that
            is entirely crates.io.
        build_data (dict): `{"files": {path: label}, "env": {var: directory}}`
            from `metadata.build_data`: the pinned files a dependency's build
            script would otherwise download, and the variables pointing it at
            them. Empty for a closure whose build scripts fetch nothing.
        build_args (list[str]): Extra `cargo build` arguments from
            `metadata.build_args`, templated via `PGRX_ARG_SUBST` (`{pg_config}`
            / `{sysroot}`).
        remap_paths (dict[str, dict[str, str]]): `{file: {from: to}}` from
            `metadata.remap_paths`, applied to the sysroot's `usr/bin/<file>`
            scripts exactly as in the PGXS path.
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
        prologue_extra = _PROLOGUE_EXTRA + (
            _PROLOGUE_SQL_GENERATOR if sql_generator else ""
        ),
        extra_srcs = [
            vendor_tar,
            cargo_lock,
            _RUST_TARGET_CARGO,
            _RUST_TARGET_FILES,
        ] + [
            build_data["files"][path]
            for path in sorted(build_data.get("files", {}))
        ],
        extra_tools = [_CARGO, _RUST_FILES] + (
            [sql_generator] if sql_generator else []
        ),
        extra_format_kwargs = {
            "build_data": _build_data_config(build_data),
            "cargo": _CARGO,
            "cargo_lock": cargo_lock,
            # Interpolated straight onto `$src`, so it carries its own leading
            # separator and stays empty for a single-crate tree.
            "crate_dir": "/" + crate_dir if crate_dir else "",
            "ext_version": ext_version,
            "git_sources": _git_sources_config(git_sources),
            "install_sql": _install_sql(sql_source, ext_version),
            "pg_major": base_version["version"].split(".")[0],
            "sql_generator": sql_generator or "",
            "target_cargo": _RUST_TARGET_CARGO,
            "vendor_tar": vendor_tar,
        },
        arg_subst = PGRX_ARG_SUBST,
        build_args = build_args,
        build_args_indent = 16,
        remap_paths = remap_paths,
        remap_paths_indent = 12,
        debug = debug,
    )
