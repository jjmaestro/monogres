# 📎 Examples

This Bazel module is a **separate workspace** that depends on monogres as an
external dependency (via `local_path_override` in `MODULE.bazel`). It serves
two distinct audiences, kept cleanly separated:

- **`public/`**: a minimal pedagogical consumer that doubles as "monoext in ~30
  lines" documentation. Read this first to learn how the API is used from
  downstream.
- **`private/`**: internal exhaustive e2e tests. They exercise every surface
  generating hubs (`@pg`, `@pg_ext`, `@pg_pkgs`) with a uniform three-phase
  pattern: load-and-enumerate → invariant assertions → one-or-two real builds.

## 🗂️ Structure

```text
examples/
├── public/
│   └── consumer/       Minimal build_test over one target from each of @pg,
│                       @pg_ext and @pg_pkgs. Doubles as API docs (README.md).
└── private/
    ├── base/
    │   ├── consumer/   Downstream-consumer contract for @pg: cfg.bzl
    │   │               enforces deps coherence on every target at load
    │   │               time; invariants check target.deps.{buildtime,
    │   │               runtime}.{sysroot,packages} shape; one
    │   │               default-target build + its four deps labels.
    │   │
    │   └── (root)      @pg hub: "Layer 1", CFG / VERSIONS / OPTION_SETS +
    │                   INTROSPECTIONS structural checks plus one build to
    │                   test (version, option_set).
    ├── ext/
    │   ├── consumer/   Downstream-consumer contract for @pg_ext: cfg.bzl
    │   │               enforces deps coherence at load time (repo
    │   │               metadata ↔ target.deps.{buildtime,runtime}.sysroot);
    │   │               invariants check source / artifact / deps label
    │   │               shape; one citus build + its deps labels.
    │   │
    │   ├── external/   @pg_ext external extensions: per-ext CFGS, REPOS,
    │   │               target-label invariants, one citus build.
    │   │
    │   └── contrib/    @pg_ext contribs: CFGS_CONTRIB, per-PG target
    │                   invariants plus one build (pgcrypto).
    │
    └── pkgs/           @pg_pkgs structure: per-package + sysroot key
                        invariants, one sysroot flatten build.
```

Rationale:

- **Public vs private** split reflects different audiences and stability
  expectations. Public is user-facing (churn is bad, doubles as docs); private
  is internal (churn is fine, grows with the API).
- **Exhaustion belongs in analysis, not builds.** Loading `all.bzl` and walking
  `CFGS` / `EXTENSIONS` / `REPOS` validates every generated target's shape for
  free. Real builds are reserved for 1–2 picks per area to exercise the
  end-to-end pipeline.
- **No overlap with unit tests** under `build/monoext/tests/`. Unit tests cover
  pure helpers (schema roundtrips, render helpers, compat logic); these e2e
  tests check that the pieces fit together and the hub repos generate
  correctly.

Each private area follows the same three-phase contract:

1. **Phase 1: Load & enumerate** (analysis-only). `BUILD.bazel` loads
   `@<hub>//:all.bzl`. If the hub generator omitted or misnamed anything, the
   load fails immediately.
2. **Phase 2: Invariants** (`unittest`-based). Structural assertions on the
   loaded data (name, versions, target label shape, compatibility, etc.). Uses
   the shared test framework at `@monogres//monoext/tests/_framework`.
3. **Phase 3: Real builds** (`build_test`). One or two representative targets
   per area are actually built. Keeps CI fast while still exercising the
   end-to-end generation pipeline. Picks per area:
   - `base/consumer`: the default PG artifact + both sysroots + one sample
     buildtime / runtime package label.
   - `base`: `@pg//{default}/{default_option_set}:{tar,introspect}` (the
     `:introspect` target forces a Layer-2 lazy fetch).
   - `ext/consumer`: citus artifact + both sysroots + one sample buildtime /
     runtime package label.
   - `ext/external`: one citus build at its default (ext, PG) pair.
   - `ext/contrib`: one pgcrypto `:tar` at the default PG version.
   - `pkgs`: one sysroot flatten target.

## ⚙️ Running

```sh
# everything (fast invariants + selected real builds):
bazel test //...

# just the public example:
bazel test //public/...

# just private e2e (by area):
bazel test //private/base/consumer/...
bazel test //private/base/...
bazel test //private/ext/consumer/...
bazel test //private/ext/external/...
bazel test //private/ext/contrib/...
bazel test //private/pkgs/...

# invariants only (no real builds, seconds not minutes):
bazel test //... --test_size_filters=small,medium

# skip only the full end-to-end (public consumer) but keep per-area builds:
bazel test //... --test_size_filters=-enormous
```

The `*_invariants` targets are `unittest`-based: they run in milliseconds. The
`*_build` targets use `build_test` to verify one representative build per area;
they take minutes.

## Related docs

- `public/consumer/README.md`: the monoext API walkthrough.
- Upstream source: `build/monoext/`, with unit tests under
  `build/monoext/tests/`.
