"""
Generate maximally-idempotent introspect JSONs for a monogres flavor hub
(`@pg`, `@ivory`, …); instantiated once per flavor in `//build/tools:BUILD.bazel`.

Usage
-----

    bazel run //build/tools:gen_pg_introspect_jsons

The build target wires every `@<hub>//<v>/<os>:introspect` (manual) target as a
data dependency, so `bazel run` builds the inputs as a prerequisite before
executing this script. Outputs are written back to the source tree under
`build/catalog/<flavor>/introspect/`: the production introspect as
`<flavor>~<v>~<os>.json`, and the test-enabled build variant
(tap_tests/injection_points on) as `<flavor>~<v>~<os>+test.json`. The script
uses the `BUILD_WORKSPACE_DIRECTORY` env var that Bazel sets when running via
`bazel run` (see `build/tools/gen_index.bzl` for the same pattern).

Why this script exists
----------------------

Postgres' Meson build emits a JSON describing the configured build (compilers,
buildoptions, targets, install plan, etc.). We check those JSONs into the
catalog so the rest of the build/test pipeline can reason about per-version
features without re-running Meson. The raw Meson output contains many tokens
that are stable for a *given build* but vary across builds, machines, archs,
sandboxes, and tool/dependency version bumps — checking them in unmodified
would produce a noisy git history every time anything changes.

This script normalizes those tokens so the checked-in JSONs are byte-stable
under any change that doesn't actually affect the introspected build state.

What we normalize
-----------------

The substitutions are applied in order (see `SUBSTITUTIONS` below). Outer
placeholders are inserted before inner patterns can depend on them.

  1. **Bazel cache root** — `~/.cache/bazel/_bazel_<user>/<hash>` on the host
     and `/cache/bazel-cache/...` in the Docker sandbox both collapse to
     `<BAZEL_CACHE>`.

  2. **Bazel sandbox / execroot** — sandboxes have ephemeral numeric suffixes
     (`linux-sandbox/12345/execroot/_main`); we replace the variable bit
     with `<SANDBOX>/<BAZEL-BUILD>`. Outside a sandbox, the path is just
     `execroot/_main`, which becomes `<BAZEL-BUILD>`.

  3. **Bzlmod canonical names** — Bazel mangles external repo names based on
     the module graph (`+monoext+pg`, `monogres++monoext+pg`,
     `+_repo_rules+pg_src`, `+monoext+pg_src-17.4`, …). We collapse both PG
     source repo shapes (`+pg_src` and `+pg_src-<v>`) to `<PG_SRC>` and the
     hub itself to `<PG_HUB>`. The PG_SRC rule must come *before* PG_HUB
     because `+pg_src` also matches the `+pg` suffix.

  4. **Bazel exec-config / mnemonic digests** — paths like
     `bazel-out/k8-opt-exec-ST-d57f47055a04/bin/external/.../__cfg00000000/`
     embed two hashes Bazel derives from the configuration graph. They are
     stable today but the algorithm has changed in past Bazel releases, so
     we normalize them defensively.

  5. **Architecture** — CPU (`aarch64` / `x86_64` / `k8`) → `<CPU>`; the
     Debian/dpkg arch (`amd64` / `arm64`) → `<ARCH>`.

  6. **Tool versions** — Python, TCL, bison, flex, LLVM versions appear in
     paths like `python_3_11_*-unknown-linux-gnu`, `libpython3.11.so`,
     `tcl8.6`, `bison_v3.3.2__cfg...`, `llvm-ar-14`. We use generic numeric
     patterns (e.g. `[0-9]+_[0-9]+`) so the rules stay valid when MODULE.bazel
     bumps any of these toolchains — no second source of truth to keep in
     sync.

  7. **PG version** — the literal version string (e.g. `17.4`) anywhere in
     the JSON becomes `<PG_VERSION>`. Done via `content.replace()` rather
     than regex because the version is known at processing time.

  8. **PG target name** — `postgres~<v>~<option_set>` (the per-build Bazel
     target name) becomes `<PG_TARGET>`. This rule was accidentally dropped
     in refactor `3f04bf30` while the rest of the script was updated for
     the @pg hub; we restore it here.

  9. **Meson internal IDs** — see the dedicated section below.

 10. **Meson anonymous-dependency names** — Meson auto-names anonymous
     dependency objects with `f'dep{id(self)}'` (see
     `mesonbuild/dependencies/base.py:109`). `id()` is the Python object's
     memory address, so these change every single Meson run. We re-number
     them by first-seen order to `<MESON_DEP_NNNN>`.

 11. **String-array fields with set-derived order** — `exclude_files` /
     `exclude_dirs` in `install_subdirs`, `depends` / `dependencies` in
     `targets` / `tests` / `benchmarks`. Meson populates these from sets
     or `os.listdir()`, so the *contents* are stable but the *order*
     isn't. We sort each such array lexicographically (after the ID
     normalizations, so the sort key is the stable placeholder, not the
     volatile underlying hex).

 12. **Colon-separated path-list env vars** — `LD_LIBRARY_PATH`, `PATH`,
     `DYLD_LIBRARY_PATH` in test/benchmark env blocks. Meson builds these
     via `':'.join(list(set_of_paths))` (see
     `mesonbuild/backend/backends.py:1266-1278`); the join order is
     `PYTHONHASHSEED`-randomized. We split on `:`, deduplicate, and
     sort. Single-path values (no `:`) pass through unchanged — they can
     still vary across runs for reasons upstream of the `:`-join but
     there's no sort key for one element.

 13. **pkgconfig dependency versions** — every entry in the top-level
     `dependencies` array records the `version` of the system library
     Meson found (icu `76.1`, openssl `3.5.1`, …). These are
     release-derived and not consumed by the build, so we replace each
     with a `<PKGCONFIG_<NAME>>` placeholder whose token is derived from
     the dependency's own `name`. Deriving the token from the JSON means a
     dependency added or bumped by a future PG or Debian release is
     covered with no new rule. Entries already carrying a placeholder
     version (the `python-<PY_VERSION>-embed` and `LLVM` deps, normalized
     by the substitution rules above) are left untouched.

 14. **List-of-dict array order** — `buildoptions`, the `dependencies`
     metadata array, and `targets` are emitted in Meson's internal order,
     which reshuffles across Meson versions (and, for `targets`, across
     any build-graph change). Consumers look these up by field value
     (`buildoptions` by `name`, `targets` by `name`/`id`; the dependency
     array is not read), never by position, so we sort each by a stable
     per-element key (`name`, or `id` for targets).

Meson target IDs (and our `<MESON_SUBDIR_NNNN>` placeholders)
-------------------------------------------------------------

In Meson terminology these are **target IDs**. A "target" is the canonical
word for a buildable thing — every Meson `Target` subclass (`Executable`,
`StaticLibrary`, `SharedLibrary`, `CustomTarget`, `RunTarget`, …) inherits
a `get_id()` method that returns:

    <7-hex>@@<name>@<3-letter-type>

The "target" concept maps cleanly across build systems:

    Meson      target              get_id() -> <hash>@@<name>@<type>
    CMake      target              add_executable, add_library, add_custom_target
    Bazel      label / rule        //path:name
    Ninja      build edge          build out: rule in
    Make       rule                target: deps  /  recipe
    Gradle     task                project:task

(Ninja is Meson's actual backend, so Meson targets ultimately compile down
to Ninja build edges.)

Decomposition of the three parts:

  - `<7-hex>` — Meson's source comments call this `parent_name_hash`; in
    this script we call it the **subdir slug**. It is
    `hashlib.sha256(subdir.encode('utf-8'))[:7]`, where `subdir` is the
    source directory containing the target, relative to the Meson project
    root. Multiple targets defined in the same `meson.build` share this
    prefix.

  - `<name>` — the user-facing target name from the corresponding
    `meson.build` call. Forward and backward slashes in names are
    replaced by `@`.

        executable('psql', sources, ...)        -> name = 'psql'
        library('libpgcommon', sources, ...)    -> name = 'libpgcommon'
        custom_target('expand-dat-files', ...)  -> name = 'expand-dat-files'

  - `<3-letter-type>` — the kind suffix, returned by
    `Target.type_suffix()` on the concrete subclass:

        exe = Executable       sta = StaticLibrary    sha = SharedLibrary
        cus = CustomTarget     run = RunTarget

    (Meson has more obscure variants like `Jar` / `BothLibraries`; we
    haven't observed those in PG introspect output.)

See `mesonbuild/build.py:605-631` (`Target._get_id_hash` +
`Target.construct_id_from_path`) for the canonical algorithm.

The subdir slug exists *only* to disambiguate the case where the same
`<name>@<type>` appears in multiple subdirs (in our build: 9 such pairs
out of ~944 — `autoinc@sha`, `refint@sha`, `gram@cus`, `define.c@cus`,
`describe@exe`, `sqlda.c@cus`, etc., because PG defines those test/regress
helpers in multiple directories). For the remaining ~935 unique
`<name>@<type>` pairs the slug carries no information.

The slug is deterministic for a given checkout (same `subdir` always →
same `sha256(subdir)[:7]`), but it is volatile across **Meson upgrades** —
if a future Meson version tweaks how `subdir` is normalized before hashing
(encoding, separator handling, …) every ID would shift, producing a
massive but semantically empty diff.

To make target IDs idempotent we normalize per `(name, type)` group:

  1. Find all `<7-hex>@@<name>@<type>` matches in the file.
  2. Group by `(name, type)`.
  3. Within each group, sort the distinct slugs lexicographically.
  4. Replace each slug with `<MESON_SUBDIR_NNNN>` (1-based, 4-digit
     zero-padded).

So `<MESON_SUBDIR_0001>@@<name>@<type>` means "the first (sorted) source
subdirectory that owns a target called `<name>@<type>` in this JSON". The
placeholder name reflects the *semantics* (a subdir slug), not the
original format (a 7-hex string).

This is stable as long as the SET of subdirs containing target
`<name>@<type>` doesn't change — adding or removing targets in *unrelated*
subdirs has no effect on this group's numbering.

Tradeoffs:

  - **Locally stable**: changes to subdir X only shift indexes in the
    `(name, type)` groups that subdir X owns; other groups untouched.
  - **No "same slug means same subdir" signal preserved across groups**:
    if subdir-slug `cae59eb` owns both `autoinc@sha` (group A) and
    `refint@sha` (group B), it gets index 1 in both groups by coincidence
    of sort order, not by design. This is fine because the meaningful
    identifier is the `(name, type)` pair; the placeholder index only
    disambiguates within the group.
  - **Idempotent**: re-running on already-normalized output is a no-op,
    since `MESON_SUBDIR_NNNN` is 4 digits + underscores (not 7-hex).
"""  # noqa: INP001  (standalone script, not a Python package)

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import time
import traceback
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
from itertools import repeat
from pathlib import Path

# Module-level logger so workers and the driver share the same channel.
# Configured once in `main()` to keep imports side-effect-free.
_LOG = logging.getLogger("gen_pg_introspect_jsons")

# Error messages — extracted to module level for ruff EM/TRY compliance and
# to make them easy to grep for when debugging a bazel-run failure.
_ERR_NO_RUNFILES = (
    "Could not locate a runfiles tree from {script}. Invoke via "
    "`bazel run //build/tools:gen_pg_introspect_jsons`."
)
_ERR_NO_WORKSPACE = (
    "BUILD_WORKSPACE_DIRECTORY is not set. This script must be invoked "
    "via `bazel run //build/tools:gen_pg_introspect_jsons`."
)
_ERR_NO_INPUTS = (
    "No introspect tar.json files found in runfiles. The data deps in "
    "//build/tools:gen_pg_introspect_jsons may have failed to build."
)

# ---------------------------------------------------------------------------
# Substitution rules
# ---------------------------------------------------------------------------
#
# Each entry is `(compiled_pattern, replacement)`. The replacement is a
# `re.sub`-style template string (so backrefs like `\1` work).
#
# **Order matters**: rules that introduce placeholders (e.g. `<BAZEL_CACHE>`)
# must precede rules that consume them. The PG_SRC rule must precede PG_HUB
# because `+pg_src` would otherwise be (partially) matched as `+pg`.

SUBSTITUTIONS: list[tuple[re.Pattern[str], str]] = [
    # --- Bazel cache root ---
    # Matches both host (~/.cache/bazel/_bazel_<user>/<hash>) and container
    # (/cache/bazel-cache/bazel/_bazel_root/<hash>) layouts.
    (re.compile(r'/[^"]*_bazel_[a-z]+/[a-f0-9]+'), "<BAZEL_CACHE>"),
    # --- Bazel sandbox / execroot ---
    (
        re.compile(r"<BAZEL_CACHE>/sandbox/[a-z]+-sandbox/[0-9]+/execroot/_main"),
        "<BAZEL_CACHE>/<SANDBOX>/<BAZEL-BUILD>",
    ),
    (re.compile(r"<BAZEL_CACHE>/execroot/_main"), "<BAZEL_CACHE>/<BAZEL-BUILD>"),
    # Bare execroot: under the hermetic chroot the execroot is mounted at
    # `/execroot/_main` with no cache prefix. Runs after the cache-prefixed
    # rules so their match wins when the prefix is present.
    (re.compile(r"/execroot/_main"), "<BAZEL-BUILD>"),
    # --- Bzlmod canonical repo names ---
    # The source/hub repo-name normalization (`+<hub>_src` -> <PG_SRC>,
    # `+<hub>` -> <PG_HUB>) is applied in `make_comparable`, parameterized by
    # the hub repo name so it covers every flavor hub (`pg`, `ivory`, …).
    # --- Bazel exec-config / mnemonic digests ---
    # `__cfg<hash>` is Bazel's per-config marker; `-ST-<hash>` is the
    # mnemonic digest embedded in `bazel-out/<arch>-opt-exec-ST-<hash>/`.
    # Both are derived from the configuration graph and are stable today
    # but have changed across Bazel releases.
    (re.compile(r"__cfg[0-9a-f]+"), "__cfg<CFG>"),
    (re.compile(r"-ST-[0-9a-f]+"), "-ST-<DIGEST>"),
    # --- Architecture ---
    # Order matters: match the most specific form first so a general rule does
    # not consume part of it (longest to shortest):
    #   <GNU_TRIPLET>  clang target triple `x86_64-unknown-linux-gnu`, in the
    #                  clang `--target=` flags; sanitized so the committed
    #                  introspect stays byte-stable across arch/release.
    #   <MULTIARCH>    Debian multiarch tuple `x86_64-linux-gnu`, in library
    #                  dirs and `-I`/`-L` flags.
    #   <CPU>          bare CPU name (aarch64 / x86_64), plus gcc's `k8` alias.
    #   <ARCH>         Debian/dpkg arch (amd64 / arm64), a distinct value (the
    #                  sysroot root is keyed `debian/<v>/<ARCH>/`).
    # If <CPU> ran before the tuple/triple it would rewrite their CPU segment and
    # they could no longer match as a unit. Triple / tuple / CPU / dpkg-arch use
    # lookarounds rather than `\b` so they still match next to `_` (e.g.
    # `python_3_11_x86_64`, the bsd_tar repo `..._linux_amd64`), which `\b` treats
    # as a word char and would miss. gcc's short `k8` alias keeps a `\b`.
    (
        re.compile(
            r"(?<![A-Za-z0-9])(?:x86_64|aarch64)-unknown-linux-gnu(?![A-Za-z0-9])",
        ),
        "<GNU_TRIPLET>",
    ),
    (
        re.compile(
            r"(?<![A-Za-z0-9])(?:x86_64|aarch64)-linux-gnu(?![A-Za-z0-9])",
        ),
        "<MULTIARCH>",
    ),
    (re.compile(r"(?<![A-Za-z0-9])(?:aarch64|x86_64)(?![A-Za-z0-9])"), "<CPU>"),
    (re.compile(r"\bk8\b"), "<CPU>"),
    (re.compile(r"(?<![A-Za-z0-9])(?:amd64|arm64)(?![A-Za-z0-9])"), "<ARCH>"),
    # --- Tool versions ---
    # All patterns use `[0-9]+` so they keep matching when MODULE.bazel
    # bumps the corresponding toolchain — no second source of truth.
    #
    # rules_python's per-platform repo name uses underscore-separated
    # major_minor (e.g. `python_3_11_x86_64-unknown-linux-gnu`).
    (re.compile(r"python_[0-9]+_[0-9]+_"), "python_<PY_VERSION>_"),
    # pkgconfig / system Python (`python3.11`, `python-3.11-embed`,
    # `/usr/include/python3.11`, `libpython3.11.so`). The separator before
    # the version is optional (none for `python3.11`, `-` for
    # `python-3.11`, etc.) and preserved in the replacement.
    (re.compile(r"python([._-]?)[0-9]+\.[0-9]+"), r"python\1<PY_VERSION>"),
    # System TCL (`tcl8.6`, `libtcl8.6.so`, `libtclstub8.6.so`,
    # `/usr/include/tcl8.6`).
    (re.compile(r"tcl[0-9]+\.[0-9]+"), "tcl<TCL_VERSION>"),
    # System Perl (`/usr/share/perl/5.36`, `/usr/lib/<ma>/perl/5.36/CORE`,
    # `libperl5.36`); same optional-separator shape as Python above.
    (re.compile(r"perl([._/-]?)[0-9]+\.[0-9]+"), r"perl\1<PERL_VERSION>"),
    # --- Debian release version ---
    # Per-release sysroot paths carry the release version
    # (`…/sysroots+<x>_sysroot/debian/12/<ARCH>/…`, keyed by the dpkg arch); the
    # version segment is release-derived, so normalize it for a byte-stable
    # introspect.
    (re.compile(r"debian/[0-9]+"), "debian/<DEBIAN_VERSION>"),
    # --- Metadata version fields ---
    # Meson's dependency/compiler detection records literal versions that are
    # not consumed by the build but are still release-derived. Sanitize the
    # python dep's `version` (anchored on its already-normalized
    # `python-<PY_VERSION>-embed` name) and the C/C++ compiler's clang
    # `version` + `full_version` (anchored on the `clang` full_version).
    (
        re.compile(r'(python-<PY_VERSION>[^}]*?"version": ")[0-9]+\.[0-9]+'),
        r"\1<PY_VERSION>",
    ),
    (
        re.compile(r"clang version [0-9]+(?:\.[0-9]+)+"),
        "clang version <LLVM_FULL_VERSION>",
    ),
    (
        re.compile(
            r'("version": ")[0-9]+(?:\.[0-9]+)+'
            r'("[^}]*?"full_version": "[^"]*clang)',
        ),
        r"\1<LLVM_FULL_VERSION>\2",
    ),
    # The LLVM `config-tool` dependency records its own `version` with no
    # clang `full_version` beside it, so the compiler rule above misses it;
    # anchor on the dependency name instead.
    (
        re.compile(r'("name": "LLVM"[^}]*?"version": ")[0-9]+(?:\.[0-9]+)+'),
        r"\1<LLVM_FULL_VERSION>",
    ),
    # rules_bison / rules_flex repo names (`bison_v3.3.2__cfg…`,
    # `flex_v2.6.4__cfg…`).
    (re.compile(r"bison_v[0-9]+\.[0-9]+\.[0-9]+"), "bison_v<BISON_VERSION>"),
    (re.compile(r"flex_v[0-9]+\.[0-9]+\.[0-9]+"), "flex_v<FLEX_VERSION>"),
    # LLVM version references appear in three shapes in the introspect output:
    #   - the dashed binary form (`llvm-ar-<LLVM_VERSION>`), used by older
    #     toolchains where the version is part of the binary name;
    #   - the path-segment form (`/usr/lib/llvm-<LLVM_VERSION>/bin/llvm-ar`),
    #     used by newer toolchains where the version is in the parent
    #     directory and the binary itself is unversioned;
    #   - the JIT link flag (`-lLLVM-<LLVM_VERSION>`), which links the
    #     versioned libLLVM shared object. This one is UPPERCASE, so the
    #     lowercase path/tool patterns below do not catch it.
    # Word boundaries on the path-segment pattern keep us from matching
    # e.g. `toolchains_llvm` or `+toolchains_llvm++llvm+...`.
    (re.compile(r"llvm-ar-[0-9]+"), "llvm-ar-<LLVM_VERSION>"),
    (re.compile(r"\bllvm-[0-9]+\b"), "llvm-<LLVM_VERSION>"),
    (re.compile(r"-lLLVM-[0-9]+"), "-lLLVM-<LLVM_VERSION>"),
]

# Pattern for Meson target IDs (see the module docstring for the full
# anatomy). Anchored to the exact shape `construct_id_from_path()` emits:
# the 7-hex subdir slug, `@@`, the target name (no `"` or `@`), `@`,
# the 3-letter type suffix. The negative lookbehind prevents matching the
# tail of a longer hex run (e.g. a stray Bazel digest left over by other
# substitution rules).
_MESON_ID_PATTERN = re.compile(
    r'(?<![0-9a-f])([0-9a-f]{7})@@([^"@]+)@([a-z]+)',
)

# Pattern for Meson anonymous-dependency auto-names. When user code calls
# `dependency(...)` without naming the result, Meson constructs a
# `Dependency` object whose default name is `f'dep{id(self)}'` (see
# `mesonbuild/dependencies/base.py:109`). `id()` is the Python object's
# memory address — on 64-bit hosts, a 14-19 digit decimal that changes
# every process. The 10-digit floor protects against matching legitimate
# short user-chosen names like `dep1`, `dep2024`, etc.; word boundaries on
# both sides keep us from eating into adjacent tokens.
_MESON_DEP_PATTERN = re.compile(r"\bdep[0-9]{10,}\b")

# JSON string-array fields whose element order Meson does not stabilize —
# typically built from set iteration or `os.listdir()`. Sorting them makes
# the catalog byte-stable across forced rebuilds without affecting
# downstream semantics (consumers index by value, not by position).
#
# Concrete sources observed (Meson 1.x, PG 16-18 introspect):
#   - `exclude_files`/`exclude_dirs` in `install_subdirs` entries:
#     `os.listdir()`-derived directory contents (inode order).
#   - `depends` in `tests`/`benchmarks` entries: built from
#     `TestSerialisation.depends` which is populated from a set.
#   - `depends`/`dependencies` in `targets`/`dependencies` entries:
#     same — sourced from Meson sets that lose insertion order.
#
# Field-name set is matched structurally (after JSON parse) rather than via
# regex on the raw text — see `_normalize_structural` for the rationale.
# The same field name can appear at multiple nesting depths (e.g.
# `targets[*].depends` and `tests[*].depends`); we walk the object tree
# and only sort when the value is actually a list-of-strings, which
# naturally skips the top-level `dependencies` array (which is a
# list-of-dicts).
_SORTABLE_STRING_ARRAY_FIELDS = frozenset({
    "exclude_files",
    "exclude_dirs",
    "depends",
    "dependencies",
})

# Top-level list-of-dict arrays whose element order Meson does not stabilize
# across versions (`buildoptions`, the `dependencies` metadata array) or across
# build-graph changes (`targets`). Each maps the field name to the per-element
# key we sort on. Consumers index these by field value (`build_introspect`
# looks up `buildoptions` by `name` and `targets` by `name`/`id`; the
# dependency array is not read at all), never by position, so canonicalizing
# the order is semantically inert and makes the catalog byte-stable across
# Meson upgrades that merely reshuffle emission order. `dependencies` also
# appears in `_SORTABLE_STRING_ARRAY_FIELDS` (the per-target list-of-strings
# form); the two shapes are disjoint and dispatched by element type.
_SORTABLE_OBJECT_ARRAY_FIELDS = {
    "buildoptions": "name",
    "dependencies": "name",
    "targets": "id",
}

# Env-var values that Meson emits as colon-separated path lists built from
# Python sets. Meson assembles them roughly as
# `t_env.prepend(NAME, list(ld_lib_path), ':')` where `ld_lib_path` is
# itself a `set[str]` (see `mesonbuild/backend/backends.py:1266-1278`).
# `list(set_of_strings)` iterates in `PYTHONHASHSEED`-randomized order, so
# the resulting `:`-joined value can shuffle across runs. We split on `:`,
# deduplicate and sort to canonicalize.
#
# Scope is limited to known path-list env vars so we never accidentally
# split a `:` that isn't a path separator (e.g. a timestamp).
_PATH_LIST_ENV_VARS = frozenset({"LD_LIBRARY_PATH", "PATH", "DYLD_LIBRARY_PATH"})

# Path components that identify an introspect tar.json among the runfiles
# tree. Layout: .../external/+monoext+pg/<v>/<os>/introspect/tar.json
_INTROSPECT_JSON_NAME = "tar.json"
_INTROSPECT_DIR_NAME = "introspect"
# The legacy script excluded `copy_introspect` rules; keep that behavior.
_COPY_INTROSPECT_DIR_NAME = "copy_introspect"
# The test-enabled build variant nests its introspect under an extra `test/`
# segment (`.../<v>/<os>/test/introspect/tar.json`). Its build flips tap_tests
# on (plus injection_points where the version supports it), so it is written
# into the shared `introspect/` catalog under a `+test` filename variant
# (`<flavor>~<v>~<os>+test.json`) beside the tap-disabled production sibling.
_TEST_VARIANT_DIR_NAME = "test"
_TEST_VARIANT_SUFFIX = "+test"
# Make-built versions synthesize their introspect JSON as a genrule output
# named `tar.introspect.json` directly in the option-set package (there is no
# separate `introspect/` rule directory on the make path). Layout:
# .../external/+monoext+pg/<v>/<os>/tar.introspect.json
_MAKE_INTROSPECT_JSON_NAME = "tar.introspect.json"

# ---------------------------------------------------------------------------
# `.control requires` enrichment
# ---------------------------------------------------------------------------
#
# PostgreSQL ships each contrib extension with a `<name>.control` file at
# `contrib/<name>/<name>.control` (sometimes also `<name>3u.control` etc.).
# The `requires = '...'` directive declares install-time PG-extension deps
# (e.g. `earthdistance` requires `cube`; `hstore_plperl` requires
# `hstore,plperl`). Neither Meson's introspect output nor the make-side synth
# captures it, so this generator walks each version's source tree (handed in
# via `--src <v>=<runfiles path>`) and adds a top-level `contrib_requires`
# key to every generated JSON. Layer 1 (`pg_introspect_paths_repo`) surfaces
# it per contrib as an optional `requires` key, which `gen_contrib`
# propagates into the per-contrib catalog `repo.json`.

# Match `requires = '...'` (single-quoted) or `requires = "..."`
# (double-quoted) or `requires = bareword`. PG's contrib `.control` files are
# mostly single-quoted, but all forms are accepted (the GUC scanner in core
# does too). Multi-line not needed: `requires` is always one comma-separated
# string in upstream contribs.
_REQUIRES_RE = re.compile(
    r"""
    ^\s*requires\s*=\s*       # the key
    (?:
        '(?P<sq>[^']*)'       # single-quoted
        | "(?P<dq>[^"]*)"     # double-quoted
        | (?P<bare>\S+)       # bareword (no spaces, no commas)
    )
    \s*(?:\#.*)?$             # optional trailing # comment
    """,
    re.VERBOSE | re.MULTILINE,
)


def parse_requires(content: str) -> list[str]:
    """Parse the `requires` directive from a `.control` file's contents.

    Returns a sorted, deduplicated list of extension names. Empty list if
    the file has no `requires` line. If multiple `requires` lines exist
    (none of the upstream contribs do this), the last one wins (matches
    PG's own .control parser behavior).
    """
    matches = list(_REQUIRES_RE.finditer(content))
    if not matches:
        return []
    last = matches[-1]
    raw = last.group("sq") or last.group("dq") or last.group("bare") or ""
    if not raw.strip():
        return []
    parts = [p.strip() for p in raw.split(",")]
    return sorted({p for p in parts if p})


def walk_contrib_controls(src_dir: Path) -> dict[str, list[str]]:
    """Walk `<src_dir>/contrib/*/<*.control>` and return a contrib_requires dict.

    Keys are contrib subdir names (e.g. `earthdistance`, `hstore_plperl`).
    Values are sorted lists of `requires` extensions. Contribs with no
    `requires` are omitted (skip-on-empty, matching the per-contrib
    INTROSPECTION dict convention in `introspect.bzl`).

    When a contrib ships multiple `.control` files (e.g. `hstore_plpython`
    ships `hstore_plpython3u.control` only; older PGs shipped per-version
    control files), all are parsed and their `requires` unioned.
    """
    contrib_dir = src_dir / "contrib"
    if not contrib_dir.is_dir():
        return {}

    out: dict[str, list[str]] = {}
    for sub in sorted(contrib_dir.iterdir()):
        if not sub.is_dir():
            continue
        names: set[str] = set()
        for control in sorted(sub.glob("*.control")):
            try:
                content = control.read_text(errors="replace")
            except OSError:
                continue
            names.update(parse_requires(content))
        if names:
            out[sub.name] = sorted(names)
    return out


def enrich_with_requires(cleaned: str, src_dir: Path | None) -> str:
    """Add a top-level `contrib_requires` key to a normalized JSON string.

    Runs AFTER `make_comparable` so the re-emit preserves the normalized
    content; `json.dumps(indent=4)` matches the formatting contract
    documented on `normalize_structural`. Skip-on-empty: no source dir, no
    contrib dir, or no contrib with `requires` leaves the JSON unchanged.

    Defers to a producer-emitted `contrib_requires` key when one is already
    present: the make path's synth script walks the MERGED source tree
    (overlay contribs included), which this primary-tree walk cannot see, so
    its data is strictly more complete.
    """
    if src_dir is None or not src_dir.is_dir():
        return cleaned
    data = json.loads(cleaned)
    if "contrib_requires" in data:
        return cleaned
    contrib_requires = walk_contrib_controls(src_dir)
    if not contrib_requires:
        return cleaned
    data["contrib_requires"] = contrib_requires
    return json.dumps(data, indent=4) + "\n"


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------


def normalize_meson_ids(content: str) -> str:
    """Normalize Meson `<7-hex>@@<name>@<type>` target IDs.

    See the module docstring for the full rationale. Short version: the
    7-hex prefix is the **subdir slug** (`sha256(subdir)[:7]`) that Meson
    embeds in every `Target.get_id()`. Since the slug only carries
    information when the same `<name>@<type>` appears in multiple subdirs,
    we re-index it per `(name, type)` group so that re-runs produce
    byte-identical output as long as the build's logical state is
    unchanged.
    """
    # First pass: collect, per (name, type) group, the distinct subdir slugs.
    groups: dict[tuple[str, str], set[str]] = defaultdict(set)
    for slug, name, type_ in _MESON_ID_PATTERN.findall(content):
        groups[name, type_].add(slug)

    # Build the (slug, name, type) -> placeholder map. Sorting the slugs
    # within each group lexicographically gives us a deterministic 1-based
    # index per group.
    mapping: dict[tuple[str, str, str], str] = {}
    for (name, type_), slugs in groups.items():
        for idx, slug in enumerate(sorted(slugs), start=1):
            mapping[slug, name, type_] = f"<MESON_SUBDIR_{idx:04d}>"

    # Second pass: substitute. `m[1]/m[2]/m[3]` are the slug/name/type
    # capture groups defined in `_MESON_ID_PATTERN`.
    def _sub(m: re.Match[str]) -> str:
        placeholder = mapping[m[1], m[2], m[3]]
        return f"{placeholder}@@{m[2]}@{m[3]}"

    return _MESON_ID_PATTERN.sub(_sub, content)


def normalize_dep_ids(content: str) -> str:
    """Normalize Meson anonymous-dependency names (`dep<id(self)>`).

    These are 100% volatile across builds because Meson uses Python's `id()`
    (a memory address) for the default name. Unlike the target IDs there is
    no semantic identifier to sort by, so we re-number in first-seen order
    within the file: the first distinct `dep<N>` encountered becomes
    `<MESON_DEP_0001>`, the next `<MESON_DEP_0002>`, etc.

    This is stable across builds as long as Meson emits anonymous deps in
    the same relative order — which it does for an unchanged build graph
    (the JSON output is generated by walking the same Python data
    structures in the same order).
    """
    seen: dict[str, str] = {}

    def _sub(m: re.Match[str]) -> str:
        token = m.group(0)
        if token not in seen:
            seen[token] = f"<MESON_DEP_{len(seen) + 1:04d}>"
        return seen[token]

    return _MESON_DEP_PATTERN.sub(_sub, content)


def _placeholder_dep_version(dep: dict) -> None:
    """Replace a dependency's release-derived `version` with a name-keyed token.

    Each entry in the top-level `dependencies` array records the version of the
    system library Meson found (e.g. icu `76.1`). That value is release-derived
    and not consumed by the build, so it becomes `<PKGCONFIG_<NAME>>`, the token
    derived from the dependency's own `name`. Because the token comes from the
    JSON, a dependency added or bumped by a future release is covered with no
    new rule. Entries whose version is already a placeholder (the python-embed
    and LLVM deps, handled by the substitution rules) are left untouched.
    """
    name = dep.get("name")
    version = dep.get("version")
    if isinstance(name, str) and isinstance(version, str) and "<" not in version:
        token = re.sub(r"[^0-9A-Za-z]+", "_", name).strip("_").upper()
        dep["version"] = f"<PKGCONFIG_{token}>"


def _sort_object_arrays(node: dict) -> None:
    """Sort the list-of-dict fields named in `_SORTABLE_OBJECT_ARRAY_FIELDS`.

    For `dependencies` each entry's release-derived `version` is first replaced
    with a name-keyed `<PKGCONFIG_<NAME>>` placeholder. The list-of-string form
    of `dependencies` (a target's dep-name list) is left to the string-array
    sort in `_normalize_node`; the two shapes are disjoint by element type, so
    the `all(isinstance(x, dict) ...)` guard here only accepts the metadata
    array.
    """
    for key, value in node.items():
        if (
            key not in _SORTABLE_OBJECT_ARRAY_FIELDS
            or not isinstance(value, list)
            or not all(isinstance(x, dict) for x in value)
        ):
            continue
        if key == "dependencies":
            for dep in value:
                _placeholder_dep_version(dep)
        sort_field = _SORTABLE_OBJECT_ARRAY_FIELDS[key]
        node[key] = sorted(value, key=lambda obj, field=sort_field: obj.get(field, ""))


def _normalize_node(node: object) -> None:
    """Recursively normalize one node of the parsed JSON tree, in place.

    Operations per dict node:

      - Any value bound to a key in `_SORTABLE_STRING_ARRAY_FIELDS` that is a
        list of strings is sorted lexicographically.
      - Any value bound to a key in `_SORTABLE_OBJECT_ARRAY_FIELDS` that is a
        list of dicts is sorted by that field's stable per-element key; for
        `dependencies` each entry's release-derived `version` is first
        replaced with a name-keyed `<PKGCONFIG_<NAME>>` placeholder. Dispatch
        is by element type, so the top-level `dependencies` (list of dicts)
        and a target's `dependencies` (list of strings) each take the right
        branch.
      - Any string value inside an `env` dict whose key is in
        `_PATH_LIST_ENV_VARS` is split on `:`, deduplicated, sorted, and
        rejoined — only if it actually contains `:`.

    After handling those, we recurse into every child so nested
    occurrences (e.g. `targets[*].dependencies` vs `dependencies[*].depends`)
    are reached.
    """
    if isinstance(node, dict):
        for key, value in node.items():
            if (
                key in _SORTABLE_STRING_ARRAY_FIELDS
                and isinstance(value, list)
                and all(isinstance(x, str) for x in value)
            ):
                node[key] = sorted(value)
        _sort_object_arrays(node)
        env = node.get("env")
        if isinstance(env, dict):
            for env_key, env_val in env.items():
                if (
                    env_key in _PATH_LIST_ENV_VARS
                    and isinstance(env_val, str)
                    and ":" in env_val
                ):
                    env[env_key] = ":".join(sorted(set(env_val.split(":"))))
        for child in node.values():
            _normalize_node(child)
    elif isinstance(node, list):
        for item in node:
            _normalize_node(item)


def normalize_structural(content: str) -> str:
    """Parse JSON, normalize field-specific orderings in place, re-emit.

    Used for transformations that are tightly bound to specific JSON
    fields (the sortable string arrays, the colon-list env vars). Doing
    them via `json.loads` + walk + `json.dumps(indent=4)` is materially
    safer than regex on the raw text:

      - regex `"field": [.*?]` can mismatch across `]` characters
        embedded in JSON string values; the parser handles JSON
        unambiguously.
      - regex `"VAR": "[^"]*"` can mismatch across escaped `\\"`
        characters inside path strings; the parser doesn't.
      - structural code is far easier to read than the lookbehind /
        lookahead gymnastics the equivalent regex requires.

    Format-preservation: `json.dumps(data, indent=4)` produces byte-equal
    output to Meson's pretty-printed format (verified empirically), plus
    a trailing newline that Meson also emits. Re-emitting therefore does
    not introduce whitespace-only diffs against a fresh `bazel run`.

    Runs AFTER the text-regex passes, so the values we operate on are
    already in their stable-placeholder form (e.g. `<MESON_SUBDIR_0001>`
    instead of the original 7-hex subdir slug).
    """
    data = json.loads(content)
    _normalize_node(data)
    return json.dumps(data, indent=4) + "\n"


def make_comparable(
    content: str,
    pg_version: str,
    hub_repo: str = "pg",
    flavor: str = "postgres",
) -> str:
    """Normalize all volatile tokens in a Meson introspect JSON.

    Args:
        content: raw contents of `tar.json`.
        pg_version: PG version string (e.g. `"17.4"`) — used for the
            `<PG_VERSION>` substitution (literal string replace; only
            applied once we've cleaned the path-based tokens).
        hub_repo: monogres hub repo name (`"pg"`, `"ivory"`, …) — drives the
            bzlmod source/hub repo-name normalization.
        flavor: catalog flavor (`"postgres"`, `"ivorysql"`, …) — drives the
            `<PG_TARGET>` target-name normalization.

    Returns:
        The normalized JSON string. Idempotent: passing the result back
        through this function returns the input unchanged.
    """
    for pattern, replacement in SUBSTITUTIONS:
        content = pattern.sub(replacement, content)
    # Bzlmod canonical repo names, parameterized by the hub repo name. The
    # per-version source repos come in two shapes (`+<hub>_src-<v>` and
    # `+<hub>_src`); `<PG_SRC>` must run before `<PG_HUB>` because `+<hub>_src`
    # also contains the `+<hub>` substring. They match disjoint path segments
    # from the rest, so applying them here yields the same output as inlining.
    content = re.sub(
        rf'external/[^/"]+\+{re.escape(hub_repo)}_src(?:-[^/"]+)?(?=[/"])',
        "external/<PG_SRC>",
        content,
    )
    content = re.sub(
        rf'external/[^/"]+\+{re.escape(hub_repo)}(?=[/"])',
        "external/<PG_HUB>",
        content,
    )
    # `pg_version` is a literal (e.g. "17.4") known at call time. Doing it
    # as a `str.replace` is faster than a regex and avoids quoting issues.
    content = content.replace(pg_version, "<PG_VERSION>")
    # `<PG_TARGET>` depends on `<PG_VERSION>` being substituted first, so
    # do it now rather than via SUBSTITUTIONS.
    content = re.sub(
        rf"{re.escape(flavor)}~<PG_VERSION>~[a-z]+",
        "<PG_TARGET>",
        content,
    )
    content = normalize_meson_ids(content)
    content = normalize_dep_ids(content)
    # Structural pass (parse / walk / re-emit) runs LAST so it operates on
    # values that are already in their stable-placeholder form.
    return normalize_structural(content)


# ---------------------------------------------------------------------------
# Driver (bazel run)
# ---------------------------------------------------------------------------


def _find_runfiles_root() -> Path:
    """Locate the `.runfiles` directory regardless of Bazel launcher.

    `py_binary` can hand control to the script via multiple paths:

      - the C++ stub binary (sets `$RUNFILES_DIR` and passes the binary
        as `argv[0]`, so `argv[0] + ".runfiles"` works);
      - the legacy shell stub (`$RUNFILES_DIR` may not be set, but it
        execs Python on the source `.py` directly — so `argv[0]` is
        already inside the runfiles tree);
      - a manual `bazel-bin/<pkg>/<name>` invocation (same as above).

    The robust common denominator: every variant guarantees that *this
    file*, when reached from a `bazel run`, lives somewhere under an
    ancestor whose name ends in `.runfiles`. We walk up from `__file__`
    looking for that ancestor, falling back to env vars and the legacy
    `argv[0] + ".runfiles"` shape if the walk fails.

    Raises:
        SystemExit: when the script is being run outside any runfiles
            tree (typically a direct `python3 gen_pg_introspect_jsons.py`).
    """
    # 1. Env vars (set by some launchers).
    for env_var in ("RUNFILES_DIR", "JAVA_RUNFILES"):
        val = os.environ.get(env_var)
        if val and Path(val).is_dir():
            return Path(val)

    # 2. Walk up from this file. Inside runfiles the script lives at
    #    `<root>.runfiles/<workspace>/<package>/this_file.py`, so the
    #    `*.runfiles` ancestor is exactly two or three levels up.
    #
    #    We deliberately do NOT call `.resolve()` here: Bazel may have
    #    placed `__file__` in runfiles as a symlink pointing back into
    #    the source tree, and resolving would take us out of the
    #    runfiles tree entirely.
    here = Path(__file__).absolute()
    for ancestor in here.parents:
        if ancestor.name.endswith(".runfiles") and ancestor.is_dir():
            return ancestor

    # 3. Legacy shape: `<binary>.runfiles` next to argv[0].
    fallback = Path(sys.argv[0] + ".runfiles")
    if fallback.is_dir():
        return fallback

    msg = _ERR_NO_RUNFILES.format(script=__file__)
    raise SystemExit(msg)


def _iter_runfiles_introspect_jsons() -> list[Path]:
    """Walk runfiles to find every introspect `tar.json`.

    The introspect outputs land in the runfiles tree at:

        <runfiles>/<canonical-pg-hub>/<v>/<os>/introspect/tar.json

    The canonical name of `@pg` is generated by Bzlmod from the module
    graph (`+monoext+pg`, `monogres++monoext+pg`, …). We don't hard-code
    it — we just look for any `tar.json` whose path contains an
    `introspect` segment and *no* `copy_introspect` segment.
    """
    runfiles_root = _find_runfiles_root()

    results: list[Path] = []
    for candidate in runfiles_root.rglob(_INTROSPECT_JSON_NAME):
        parts = candidate.parts
        if _INTROSPECT_DIR_NAME not in parts:
            continue
        if _COPY_INTROSPECT_DIR_NAME in parts:
            continue
        results.append(candidate)

    # Make-built versions: `tar.introspect.json` sits directly in the
    # option-set package (no `introspect/` rule dir to filter on).
    for candidate in runfiles_root.rglob(_MAKE_INTROSPECT_JSON_NAME):
        if _COPY_INTROSPECT_DIR_NAME in candidate.parts:
            continue
        results.append(candidate)
    return results


def _split_version_and_option_set(tar_json: Path) -> tuple[str, str, str]:
    """Extract `(pg_version, option_set, variant)` from an introspect JSON path.

    Meson layout: `.../<v>/<os>/introspect/tar.json` (walk past the
    `introspect/` rule dir). Make layout: `.../<v>/<os>/tar.introspect.json`
    (the JSON sits directly in the option-set package).

    The test-enabled build variant nests its introspect under an extra `test/`
    segment (`.../<v>/<os>/test/introspect/tar.json` for meson,
    `.../<v>/<os>/test/tar.introspect.json` for make), so `variant` is `"test"`
    there and `"prod"` otherwise; the caller encodes it as a `+test` filename
    suffix.
    """
    option_set_dir = tar_json.parent
    if option_set_dir.name == _INTROSPECT_DIR_NAME:
        option_set_dir = option_set_dir.parent
    variant = "prod"
    if option_set_dir.name == _TEST_VARIANT_DIR_NAME:
        variant = "test"
        option_set_dir = option_set_dir.parent
    version_dir = option_set_dir.parent
    return version_dir.name, option_set_dir.name, variant


def _process_one(
    tar_json: Path,
    catalog_dir: Path,
    hub_repo: str,
    flavor: str,
    src_dirs: dict[str, str],
) -> tuple[str, str | None]:
    """Worker: read one tar.json, normalize + enrich, write to `<catalog>/<…>.json`.

    Both variants share the `introspect/` catalog dir; the test-enabled
    introspect takes a `+test` filename suffix (`<flavor>~<v>~<os>+test.json`)
    so it sits beside its production sibling.

    Top-level by necessity — `ProcessPoolExecutor` workers pickle the
    function by qualified name.

    Returns `(output_path, error_or_None)`. Errors are returned (not
    raised) so a failure in one file doesn't tear down the pool, and so
    the driver can surface every failure in a single end-of-run report.
    """
    pg_version, option_set, variant = _split_version_and_option_set(tar_json)
    suffix = _TEST_VARIANT_SUFFIX if variant == "test" else ""
    out = catalog_dir / f"{flavor}~{pg_version}~{option_set}{suffix}.json"
    src_dir_str = src_dirs.get(pg_version)
    src_dir = Path(src_dir_str) if src_dir_str else None
    try:
        cleaned = make_comparable(
            tar_json.read_text(encoding="utf-8"),
            pg_version,
            hub_repo,
            flavor,
        )
        cleaned = enrich_with_requires(cleaned, src_dir)
        out.write_text(cleaned, encoding="utf-8")
        # Mark read-only to discourage hand-edits; the legacy script
        # did the same.
        out.chmod(0o444)
    except Exception:  # noqa: BLE001 — broad catch is intentional here
        return (str(out), traceback.format_exc())
    return (str(out), None)


def _parse_src_args(src_entries: list[str]) -> dict[str, str]:
    """Resolve `--src VERSION=RUNFILES_PATH` entries to absolute source dirs.

    Raises:
        SystemExit: when an entry is not shaped `VERSION=RUNFILES_PATH`.
    """
    runfiles_root = _find_runfiles_root()
    src_dirs: dict[str, str] = {}
    for entry in src_entries:
        version, _, rel_path = entry.partition("=")
        if not rel_path:
            msg = f"--src expects VERSION=RUNFILES_PATH, got {entry!r}"
            raise SystemExit(msg)
        src_dirs[version] = str(runfiles_root / rel_path)
    return src_dirs


def main() -> int:
    # `format="%(message)s"` keeps the output uncluttered — bazel's UI
    # already prefixes every line; we don't need a redundant level tag.
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    parser = argparse.ArgumentParser(description="Normalize introspect JSONs.")
    parser.add_argument(
        "--hub",
        default="pg",
        help="monogres hub repo name (e.g. 'pg', 'ivory').",
    )
    parser.add_argument(
        "--flavor",
        default="postgres",
        help="catalog flavor (e.g. 'postgres', 'ivorysql').",
    )
    parser.add_argument(
        "--src",
        action="append",
        default=[],
        metavar="VERSION=RUNFILES_PATH",
        help=(
            "Per-version source tree (runfiles-relative path of the"
            " version's :dir alias), used to bake `.control requires` into"
            " the generated JSONs. Repeatable."
        ),
    )
    args = parser.parse_args()
    hub_repo = args.hub
    flavor = args.flavor
    src_dirs = _parse_src_args(args.src)

    workspace_env = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if not workspace_env:
        raise SystemExit(_ERR_NO_WORKSPACE)
    # `BUILD_WORKSPACE_DIRECTORY` is the directory containing MODULE.bazel,
    # which in this repo is `build/`; from the worktree root the final
    # location is `build/catalog/<flavor>/introspect/`.
    catalog_dir = Path(workspace_env).joinpath("catalog", flavor, "introspect")
    catalog_dir.mkdir(parents=True, exist_ok=True)

    # Wipe stale outputs first so renames / drops are picked up cleanly.
    for stale in catalog_dir.glob(f"{flavor}~*.json"):
        stale.chmod(0o644)  # ensure removal succeeds (we set 0444 below)
        stale.unlink()

    tar_jsons = sorted(_iter_runfiles_introspect_jsons())
    if not tar_jsons:
        raise SystemExit(_ERR_NO_INPUTS)

    # Each file is ~5 MiB of mostly regex work, and 88 of them in
    # sequence is noticeably slow. Fan out across CPUs via
    # `ProcessPoolExecutor` — Python's GIL makes a thread pool useless
    # for CPU-bound regex; subprocesses sidestep it cleanly. Default
    # `max_workers = os.cpu_count()`.
    start = time.monotonic()
    successes: list[str] = []
    failures: list[tuple[str, str]] = []
    with ProcessPoolExecutor() as executor:
        for out_path, err in executor.map(
            _process_one,
            tar_jsons,
            repeat(catalog_dir),
            repeat(hub_repo),
            repeat(flavor),
            repeat(src_dirs),
        ):
            if err is None:
                successes.append(out_path)
            else:
                failures.append((out_path, err))
    elapsed = time.monotonic() - start

    _LOG.info("wrote %d introspect JSONs in %.2fs", len(successes), elapsed)
    if failures:
        _LOG.error("%d file(s) failed to normalize:", len(failures))
        for path, tb in failures:
            _LOG.error("\n--- %s ---\n%s", path, tb)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
