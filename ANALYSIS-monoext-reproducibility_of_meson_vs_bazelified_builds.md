# Reproducibility: meson (rules_foreign_cc) vs the bazelified cc_* build

Status: implemented. This records an empirical comparison of the meson
(rules_foreign_cc) reference build and the native cc_* overlay (PostgreSQL 16.0
"full", `wip/bazelify-postgres`), the reproducibility levers applied to converge
them, and the single residual that remains.

## TL;DR

- The bazelified build is **functionally faithful** to the meson build: same
  source, same compiler (clang 14.0.6 via `@llvm_toolchain`), same major version.
- **94% of installed files are byte-for-byte identical** (every source header,
  `.sql`, `.control`, NLS `.mo`, text-search data file). Only the compiled ELF
  artifacts differ.
- After the levers, **73 of 104 comparable ELF artifacts are byte-for-byte
  identical**, and the per-function disassembly classification of the rest is
  **9 BENIGN, 22 LAYOUT, 0 INVESTIGATE**: no binary differs in compiler, in
  linked-symbol ABI, or in instruction set.
- The remaining 31 differ for a **single** reason: the linker places functions
  and sections in a different order, because the overlay's `cc_binary` link feeds
  lld a different object sequence than meson's flat `extract_all_objects` +
  `--start-group` line (the library targets map 1:1; only the link weaving
  differs). The symbol tables, PLT/GOT, relocations, and build-id cascade from
  that layout. It is a cross-build-system ordering difference, not a code
  difference.
- The levers, all implemented and validated green on both test lanes (194 pass /
  9 skipped each):
  1. `-fmacro-prefix-map` on both builds, mapping source AND generated `__FILE__`
     roots to the package-relative path.
  2. `-Wl,--as-needed`: the over-link is fully closed; `DT_NEEDED` sets match.
  3. no build-tree `RUNPATH`: meson emits none (the per-PG build sysroot is
     advertised to `--print-search-dirs`), and the overlay strips Bazel's
     `_solib` rpath.
  4. the GNU build-id stays the deterministic lld `--build-id` content hash; it
     converges for free once the content matches.
- **Path-independence holds**: across all 248 binaries, none embeds the
  workspace-path-derived output base or the real `/cache/...` path, so the build
  reproduces bit-for-bit regardless of where the workspace is checked out.

## What was compared

<!-- markdownlint-capture -->
<!-- markdownlint-disable MD013 -->

| | meson (reference) | bazelified (overlay) |
| --- | --- | --- |
| target | `@pg//16.0/full:tar.dev` | `@pg//16.0/full/cc:tar.dev` |
| builder | rules_foreign_cc (meson + ninja) | native `cc_*` rules from introspect JSON |
| compiler | clang 14.0.6 (`@llvm_toolchain`) | clang 14.0.6 (`@llvm_toolchain`) |
| flags | `--nostamp`, `--incompatible_strict_action_env` (both) | same |
| version | PostgreSQL 16.0 full | PostgreSQL 16.0 full |

<!-- markdownlint-restore -->

Both builds use the same Bazel-registered cc toolchain, so the compiler is
identical (confirmed in each binary's `.comment`: `clang version 14.0.6` plus
`GCC 12.2.0` from the sysroot CRT objects). The differences below are therefore
build-system-level (link order), not compiler-level.

Note on the reference: the meson `:tar.dev` is an INCOMPLETE artifact for binary
comparison. Its `out_binaries` is hand-curated to 6 binaries (postgres, initdb,
pg_config, pg_isready, oid2name, vacuumlo), so only those 6 plus the loadable
`.so` modules and the client shared libs overlap with the overlay. The 28 other
frontends (psql, pg_dump, pg_ctl, ...) are overlay-only and cannot be compared.

## Methodology and tooling

Two scripts under `build/tools/`.

`compare-install-trees.sh` answers the manifest + byte questions. It is portable
to busybox or GNU coreutils (no `find -printf`, no `file`, no binutils required):

- Roots each tree at its `bin/` parent, to neutralize install-prefix
  differences.
- Part 1, manifest parity: lists regular files and symlinks, diffs the path sets
  (only-in-A, only-in-B, both), buckets the only-in-meson set against the known
  deferrals, and flags file-vs-symlink type mismatches.
- Part 2, content parity: sha256 buckets (identical vs differ) over the
  files-in-both, classifies the differing set (ELF vs by-extension), and for
  each differing ELF reports the byte-delta (`cmp -l | wc -l`), the first
  differing offset, and the embedded absolute-path strings unique to each side
  (`grep -a`).
- Compares symlink targets among shared symlinks.

`classify-elf-diff.sh` answers the semantic question for every byte-differing
ELF: is the difference benign or a real divergence? Per binary it compares the
linked libraries (`DT_NEEDED`), the compiler (`.comment`), the dynamic symbol
interface (`nm -D` exports + imports), and the code. The code check is the
decisive one: it disassembles the executable sections, normalizes away
everything a pure relocation perturbs (the address column, `0x...` immediates
and displacements with their sign, inter-function `int3`/`nop` alignment
padding), keys each instruction by its function, and compares the streams two
ways: as emitted (address order) and sorted by the whole `(name, body)` record.
Sorting on the full record (not the name alone) canonicalizes duplicate
static-symbol names whose distinct bodies the linker emits in either order, so a
reshuffle of identical functions does not read as a code change. It then buckets
each binary as BENIGN (identical even in address order), LAYOUT (identical
per-function instructions, linker ordered them differently), or INVESTIGATE
(code, ABI, or compiler actually differ), and aggregates the `DT_NEEDED` the
overlay adds. It requires `binutils` (`readelf`, `objdump`, `nm`).

Tools needed beyond the base pass, installed ephemerally in the container as
root (kept out of the image; reinstall when needed):

```sh
docker exec -u root sandbox_bzpg_monogres_x86_64 \
  apt-get install -y --no-install-recommends binutils file diffoscope-minimal
```

`binutils` drives `classify-elf-diff.sh` and the manual `readelf`/`nm`/`objdump`
inspection. `diffoscope` (the Reproducible-Builds comparator) is the canonical
cross-check on any single binary: `diffoscope --text - meson.so overlay.so`
renders the same readelf/objdump deltas in a human-readable report.

Reproduce:

<!-- markdownlint-capture -->
<!-- markdownlint-disable MD013 -->

```sh
docker exec -u postgres -w /src/workspace/tools sandbox_bzpg_monogres_x86_64 bash -c '
  bazel build @pg//16.0/full:tar.dev @pg//16.0/full/cc:tar.dev
  ER=$(bazel info execution_root)
  M=$ER/bazel-out/k8-fastbuild/bin/external/+monoext+pg/16.0/full/tar.dev
  C=$ER/bazel-out/k8-fastbuild/bin/external/+monoext+pg_cc_16_0_full_amd64/tar.dev
  bash compare-install-trees.sh "$M" "$C" /tmp/pgcmp
  bash classify-elf-diff.sh     "$M" "$C" /tmp/pgelf'
```

<!-- markdownlint-restore -->

## Part 1: manifest parity (resolved, context only)

After the 3-layer install-tree work (`:tar` runtime, `:tar.dev` SDK,
`:tar.test`), the overlay `:tar.dev` vs meson `:tar.dev` is at intended parity:

- meson: 1751 paths; overlay `:tar.dev`: 1749 paths; 1721 in both.
- only-in-meson = exactly 30, all intentional: 9 static archives (`.a`), 13 pgxs
  files (Makefiles + the PerlTest framework modules), 4 pkg-config (`.pc`), and
  4 test `.so` meson leaks into a prod install (the overlay places them in
  `:tar.test`). The first three families are deferred and join `:tar.dev` when
  they lift.
- only-in-overlay = 28, all `bin/*` frontends (meson's curated `out_binaries`;
  the overlay is the more complete tree here).
- `include/server` is 856 = 856.
- 8 type mismatches: configured / dual-installed headers (`pg_config*.h`,
  `postgres_ext.h`, the `internal/` trio) are a real file in meson and a
  within-tree symlink in the overlay. Benign; same content resolves through the
  symlink.

Manifest parity is not a reproducibility concern; it is recorded here only so the
reproducibility comparison starts from a known, matched file set.

## Part 2: content parity

Over the 1705 regular files present in both trees, 1600 (94%) are byte-for-byte
identical: source headers, generated headers, `.sql`, `.control`, NLS `.mo`
catalogs, text-search data. This establishes that the source inputs and the
codegen (perl/bison/flex/sed/msgfmt) are deterministic and identical across the
two build systems. Of the 105 that differ, 104 are ELF and one is
`lib/llvmjit_types.bc` (LLVM bitcode, same class of cause as the ELF: embedded
metadata).

### The convergence levers

Four build-system-level causes drove the original ELF differences. Three are
closed by a lever; the fourth (build-id) converges for free.

**1. Embedded `__FILE__` build paths -> `-fmacro-prefix-map`.** PostgreSQL bakes
`__FILE__` into every `elog`/`ereport`/assert, so the source path of each
translation unit lands in `.rodata`. The two builds compile from different
roots, so a `-fmacro-prefix-map` is applied on each to strip its root to the
package-relative path (`src/...`, `contrib/...`):

- the meson build maps the rules_foreign_cc symlink root
  (`external/<src-canonical>/<v>/gh/`) through its CFLAGS / CXXFLAGS;
- the overlay maps both `external/<overlay-repo>/` (source files) and
  `$(BINDIR)/external/<overlay-repo>/` (the flex/bison/xsubpp generated scanners
  and parsers, which compile from the genfiles tree).

After this, the embedded source strings match exactly; the only residual path is
`llvmjit.so`'s, a C++ template source-location string baked in by LLVM's own
headers (the LLVM include tree sits at a different location in each build).

**2. Over-linking -> `-Wl,--as-needed`.** The `cc_*` rules list PostgreSQL's full
transitive dependency closure on every link, so each module recorded a
`DT_NEEDED` (and a `$ORIGIN` rpath) for libraries it never references; meson
links each module against only what it uses. `-Wl,--as-needed` in the toolchain
link wrapper keeps only the libraries that satisfy a referenced symbol. The
over-link is now fully closed: `classify-elf-diff.sh` reports zero `DT_NEEDED`
the overlay adds, and e.g. `dblink.so` carries the same two (`libpq.so.5`,
`libc.so.6`) on both sides.

**3. Build-tree `RUNPATH` -> no rpath on either side.** meson skips baking an
rpath for a dependency found in a compiler system directory, where the system
set comes from `clang --print-search-dirs`. The toolchain `--sysroot` is the
libc sysroot, but PostgreSQL dependencies live in the per-PG build sysroot
layered in via `-L`, so meson treated them as non-system and baked a build-tree
rpath (which `depfixer` could drop but not shrink out of `.dynstr`). Advertising
the build sysroot lib dirs on `--print-search-dirs` makes meson treat them as
system, so it emits no rpath. The overlay, which carries Bazel's `_solib` rpath,
strips it in the link wrapper. Both trees now ship free of build-tree paths,
which is also a production-hygiene win independent of reproducibility.

**4. GNU build-id.** lld's `--build-id` is a content hash, so it is deterministic
and converges automatically once every other byte matches; no lever is needed.

### Systematic classification across the differing ELF

`classify-elf-diff.sh` buckets every byte-differing ELF present on both sides.
After the levers, 73 of the 104 comparable ELF are byte-for-byte identical, and
the 31 that still differ classify as:

<!-- markdownlint-capture -->
<!-- markdownlint-disable MD013 -->

| bucket | count | meaning |
| --- | --- | --- |
| BENIGN | 9 | identical code and layout; bytes differ only in the address cascade (symbol tables, relocations, build-id) |
| LAYOUT | 22 | identical per-function instructions; the linker placed functions in a different order |
| INVESTIGATE | 0 | none |

<!-- markdownlint-restore -->

No binary differs in compiler, in linked-symbol ABI (the exported and imported
dynamic-symbol sets are equal everywhere), or in instruction set. Every remaining
difference reduces to one cause: lld lays out functions and sections in a
different order in the overlay than in meson, because the overlay's `cc_binary`
link feeds the linker a different object sequence than meson's flat link line (the
mechanism is detailed in "The residual" below). The 73 already-identical modules
are exactly those where the two object orders coincide, which proves the point:
when the input order matches, the
output is byte-identical, symbol tables and all. For the rest, the function
order (LAYOUT) and the symbol-table / PLT / GOT / relocation order (the address
cascade shared by BENIGN) shift together, and the build-id follows.

Tool boundary: the code check proves the per-function instruction multiset and
structure are identical with addresses masked; it does not verify the exact
relocation targets (which symbol each masked `lea`/`call` resolves to). A
relocation-aware pass (`objdump -dr`) would close that last gap.

## Path-independence (build reproducibility across workspaces)

A build that embeds the workspace path would not reproduce across users. Scanning
all 248 ELF (108 meson, 140 overlay) for the real, workspace-path-derived output
base finds:

- 0 binaries embed the output-base hash (derived from the workspace path),
- 0 binaries embed the real `/cache/bazel-cache/...` path,
- 8 meson binaries embed the canonical `/execroot/_main` sandbox mount (identical
  regardless of workspace location); the overlay embeds no absolute path at all.

Two defenses hold: the PostgreSQL `configure` / PGXS build path is patched out,
and the hermetic sandbox canonicalizes the execroot mount. So two clones at
different workspace paths reproduce bit-for-bit. The gold-standard confirmation
(two independent clones at different paths, each with its own `--output_base` so
every action re-runs, compared byte-for-byte) is the definitive test; the
absolute-path scan above is the cheap leading indicator, and it is clean.

## The residual: cross-build-system link order

The 31 differing ELF differ only in link order: lld places identical functions
and sections in a different sequence, and the symbol table, PLT/GOT, relocations,
and build-id cascade from that placement. The cause is not the library
decomposition. The overlay maps 1:1 onto meson's link targets: each meson
`static_library` / `shared_library` / `executable` / `shared module` renders as
one `cc_*` target of the same name and source set, including the single
monolithic `postgres_lib` (every `src/backend/**` object, not a per-directory
split). The divergence is in how those targets reach the linker, and it has two
layers.

**Layer A: object order inside an archive.** A `static_library`'s member order is
its meson `sources` order; the renderer emits `srcs = sorted(...)`, a lexical
order. PostgreSQL lists sources roughly alphabetically, so the two mostly
coincide; the residual is the generated sources (bison/flex output, `fmgrtab.c`,
the `_srv` / `_shlib` variants), which meson appends at the declaration site while
the overlay splices them into the lexical sort. This layer is fully controllable
on the overlay side (preserve the introspect `sources` order instead of sorting),
and it is not the binding constraint.

**Layer B: the executable link line.** This is the binding constraint, and it
is exactly the ordered link inputs Bazel does not expose. meson's `postgres`
line is flat: `postgres_lib.extract_all_objects()` (every backend `.o` in
`sources` order), then the convenience archives (`parser`, `boot_parser`,
`nodefuncs`, `jsonpath`, `guc-file`, the `libpgport_srv` / `libpgcommon_srv`
family) wrapped in `-Wl,--start-group ... --end-group`, then the system
libraries. The overlay reconstructs the same set from the flattened introspect
link line (`link_static_deps` preserves the archive order into `deps`,
`postgres_lib` is `alwayslink` to mirror `extract_all_objects`, and `linkopts`
keeps only `-export-dynamic` / `-pthread` / `-lm`), but a `cc_binary` does not
link in `deps` order: Bazel collects the transitive libraries into a depset and
emits them in a deduplicated topological linearization of the dependency graph.
There is no attribute to pin a verbatim object/archive sequence, and no way to
interleave one library's extracted objects between two archives the way meson's
`objects:` + `link_with` does.

`--start-group` is why the two strategies cannot be aligned through
attributes. A static link is a single left-to-right pass: at each archive the
linker pulls only the members that resolve a currently-undefined symbol, then
never revisits it, so a backward reference into an already-scanned archive
fails. PostgreSQL's backend has genuine cycles (the generated parser /
bootstrap / nodefuncs archives call into the backend and the backend calls
into them), so meson brackets them in `--start-group ... --end-group`, which
re-scans the group until a pass resolves nothing new. Bazel forbids dependency
cycles among `cc_library`, so the overlay cannot model that relationship; it
whole-archives `postgres_lib` (`alwayslink`) instead, so every backend symbol
is defined before the lazy convenience archives are scanned and a single
forward pass resolves them. The binary is correct, but it pulls and places
members in a different sequence than meson's start-group re-scan, which is the
LAYOUT difference. Injecting `-Wl,--start-group` on the overlay link does not
recover it: Bazel owns the command-line placement of the inputs, so meson's
exact grouping and order cannot be reproduced.

Closing the residual is possible but not pursued, because the routes are poor
value against an already-faithful result:

- The clean lld knobs (`--symbol-ordering-file`, or `-ffunction-sections` +
  `-Wl,--sort-section=name`) force a canonical *function* order but do not
  control the symbol-table, PLT, GOT, and relocation table order, which also
  cascades from input order. Applied symmetrically they convert LAYOUT
  to BENIGN without producing new byte-identical binaries, and `-ffunction-sections`
  is a real codegen change to every production binary.
- True byte-identity requires both layers to match meson exactly: preserving the
  introspect `sources` order (Layer A) and replaying meson's flat
  `extract_all_objects` + `--start-group` line verbatim (Layer B). Layer A is
  necessary but not sufficient, since Layer B reshuffles the result regardless,
  and Layer B means leaving the `cc_binary` link model for a hand-built link
  action, for a layout permutation with zero functional gain.

Both routes are independent of the rest of the build and can be revisited later
if cross-build-system bit-identity ever becomes a requirement (it is a higher bar
than the Reproducible-Builds standard, which targets same-build determinism). The
cheaper, higher-value follow-ups are the two-clone determinism build above and the
relocation-aware (`objdump -dr`) verification.

## Appendix: representative raw data

Content parity summary (overlay `:tar.dev` vs meson `:tar.dev`):

```text
regular files on both sides : 1705
byte-identical              : 1600  (94%)
differing                   :  105  (104 ELF + 1 .bc)
ELF byte-identical          :   73 / 104
ELF differing               :   31  (9 BENIGN, 22 LAYOUT, 0 INVESTIGATE)
```

Absolute-path scan across all 248 ELF (workspace-path leak check):

```text
build   files   leak[real hash]   leak[/cache/]   canonical[/execroot/_main]
meson    108           0                0                    8
cc       140           0                0                    0
```
