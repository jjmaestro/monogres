# `sysroots`

[![pre-commit](
    ../../actions/workflows/pre-commit.yaml/badge.svg
)](../../actions/workflows/pre-commit.yaml)
[![CI](
    ../../actions/workflows/ci.yaml/badge.svg
)](../../actions/workflows/ci.yaml)

Bazel module to materialize OS-package sysroots for hermetic builds.

A `sysroots.<pkg_manager>(...)` tag turns a list of OS packages into a hub
repo exposing per-arch sysroot trees, ready for [`toolchains_llvm`]'s
`--sysroot=` flag, `cc_toolchain` consumers, or any action that extracts a
tar at action time. Today only `sysroots.apt(...)` is implemented
(Debian/Ubuntu via [`rules_distroless`]); `sysroots.rpm(...)` and
`sysroots.apk(...)` are reserved as future tag classes on the same extension.

## 📦 Install

First, make sure you are running Bazel with [Bzlmod]. Then, add the module as
a dependency in your `MODULE.bazel`:

```starlark
bazel_dep(name = "sysroots", version = "<VERSION>")
```

<details>
<summary><h3>Non-registry overrides</h3></summary>

If you need to use a specific commit or version tag from the repo instead of
a version from the registry, add a [non-registry override] in your
`MODULE.bazel` file, e.g. [`archive_override`]:

<!-- markdownlint-capture -->
<!-- markdownlint-disable MD013 -->
```starlark
REF = "v<VERSION>"  # NOTE: can be a repo tag or a commit hash

archive_override(
    module_name = "sysroots",
    integrity = "",  # TODO: copy the SRI hash that Bazel prints when fetching
    strip_prefix = "bazel_sysroots-%s" % REF.strip("v"),
    urls = ["https://github.com/jjmaestro/bazel_sysroots/archive/%s.tar.gz" % REF],
)
```
<!-- markdownlint-restore -->

**NOTE**:
`integrity` is intentionally empty so Bazel will warn and print the SRI hash
of the downloaded artifact. **Leaving it empty is a security risk**. Always
verify the contents of the downloaded artifact, copy the printed hash and
update `MODULE.bazel` accordingly.

</details>

## 🚀 Getting Started

The `sysroots` module exposes a `sysroots` module extension with one tag
class per supported package manager. The primary entry point is
`sysroots.apt(...)` which materializes a Debian/Ubuntu sysroot hub repo from
a list of apt package constraints, ready for any consumer that takes a
sysroot-tree label.

Here's an example that creates a `@sysroot_debian_12` hub for a small libc /
libstdc++ toolchain sysroot:

### 1. Declare the sysroot

Add the following to `MODULE.bazel`:

<!-- markdownlint-capture -->
<!-- markdownlint-disable MD013 -->
```starlark
sysroots = use_extension("@sysroots//:extension.bzl", "sysroots")

sysroots.apt(
    name = "sysroot_debian_12",
    distro = "debian",
    version = "12",
    archs = ["amd64", "arm64"],
    packages = [
        "libc6-dev",
        "libgcc-12-dev",
        "libstdc++-12-dev",
        "linux-libc-dev",
    ],
    snapshot = "20250113T000000Z",
    lock = "//locks:sysroot_debian_12.lock",
)
use_repo(sysroots, "sysroot_debian_12")
```
<!-- markdownlint-restore -->

The `snapshot` attr pins the apt resolution to a specific Debian snapshot,
caller-supplied so the module never bakes a snapshot pin of its own.

Alternatively, the `{distro, version, archs, packages, snapshot}` fields can
live in an external JSON manifest:

```starlark
sysroots.apt(
    name = "sysroot_debian_12",
    manifest = "//path/to:manifest.json",
    lock = "//locks:sysroot_debian_12.lock",
)
```

with the schema:

<!-- markdownlint-capture -->
<!-- markdownlint-disable MD013 -->
```json
{
  "version": 1,
  "distro": "debian",
  "distro_version": "12",
  "snapshot": "20250113T000000Z",
  "archs": ["amd64", "arm64"],
  "packages": ["libc6-dev", "libgcc-12-dev", "libstdc++-12-dev", "linux-libc-dev"]
}
```
<!-- markdownlint-restore -->

Explicit tag attrs override manifest fields.

### 2. Generate the lockfile

The `lock` attr points to a JSON file that caches the resolver's output
(per-package URLs, sha256, transitive dependency closure, virtual-package
name remappings) so cold module-extension evaluations don't have to talk to
the network. Generate or refresh the lockfile with:

```sh
bazel run @sysroot_debian_12//debian/12/lock:update
```

Without a lockfile (or with a stale one) the extension warns and falls back
to live resolution against `snapshot`.

### 3. Consume the sysroot

Each per-arch subpackage in the hub repo exposes two parallel targets:

- `:sysroot`: a `filegroup(glob(["**"]))` over the extracted, normalized
  tree. Used by `--sysroot=`-style consumers that need every file plumbed
  into action inputs via Bazel's `DefaultInfo`. The canonical consumer is
  [`toolchains_llvm`]'s `llvm.sysroot(label = ...)`, which records the
  label's package path verbatim and bakes it into `--sysroot=`:

```starlark
llvm.sysroot(
    name = "llvm_toolchain",
    label = "@sysroot_debian_12//debian/12/amd64:sysroot",
    targets = ["linux-x86_64"],
)
```

- `:sysroot.tar`: a single-file tar artifact capturing the complete
  normalized tree, including files whose basenames Bazel can't represent as
  target labels (e.g. `Dpkg::Arch.3perl.gz` from `dpkg-dev`). Used by
  consumers that extract at action time and need the tree to be writable
  (e.g. for in-place patches at action time).

To list all the targets in the hub, run `bazel query
@sysroot_debian_12//...`.

## How it works

`sysroots.apt(...)` is a thin tag on top of a repository rule that:

1. Reads the lockfile (if present and valid) or resolves the closure against
   the snapshot.
2. Downloads and extracts each resolved `.deb` (two-stage:
   `rctx.download_and_extract(type="deb")` unpacks the outer `ar` layer,
   followed by an `rctx.extract` on the inner `data.tar.*`). Covers every
   `data.tar` compression Bazel's bundled decompressors handle (`xz`,
   `zstd`, `gzip`, `bzip2`, and uncompressed); see
   [`//apt/private:deb.bzl`](apt/private/deb.bzl) for the matrix and the
   known `data.tar.lzma` gap. No host `ar` / `tar` / `dpkg-deb` invocations
   needed.
3. Runs the **Tier-1 normalizations** that fix every extracted-sysroot
   pattern downstream linkers + globs don't handle:
   - **Cyclic-symlink prune.** Some packages ship symlinks pointing at one
     of their own ancestor directories, which `glob(["**"])` descends
     infinitely. The prune step removes them.
   - **Symlink relativization.** Absolute symlink targets (`/lib/.../libfoo`)
     dangle when the sysroot is bind-mounted somewhere other than `/`. Each
     absolute target is rewritten as a path relative to the symlink's
     directory so it resolves under any mount.
   - **GNU-ld script rewrite.** Debian ships `libc.so`, `libm.so`, ... as
     text-mode `GROUP ( /lib/.../libc.so.6 ... )` linker scripts. `ld.lld`
     honors `=`-prefixed paths inside `--sysroot=` but does not auto-prepend
     `--sysroot=` to bare absolute paths inside scripts. Each path after
     `(` or whitespace is `=`-prefixed.
   - **Known-package patches.** A registry maps package names to Starlark
     patcher functions for package-specific path rewrites that must land at
     repo-rule time (any path baked here must stay valid in the read-only
     `@hub` repo).
4. Writes the `:sysroot.tar` snapshot of the fully-normalized tree.
5. Runs the **Bazel-unrepresentable basename prune** on the on-disk tree
   only: removes files whose basenames contain characters Bazel forbids in
   target names (e.g. `:` in `Dpkg::Arch.3perl.gz`). The on-disk tree (over
   which the `:sysroot` filegroup globs) loses these files; the
   already-written `:sysroot.tar` retains them for action-time consumers.
6. Applies the **Tier-2 `extra_files` injection**: per-tag
   `{source_label: in_sysroot_path}` map for callers that need to drop
   files (e.g. compiler wrappers) into the sysroot tree at a canonical
   location. The path may contain a `{arch}` placeholder substituted at
   write time.
7. Emits the per-arch `BUILD.bazel` with both targets.

The hub repo layout:

```text
@<name>/
+-- BUILD.bazel
+-- <distro>/
    +-- BUILD.bazel
    +-- <version>/
        +-- BUILD.bazel
        +-- <amd64>/
        |   +-- BUILD.bazel       (:sysroot + :sysroot.tar)
        |   +-- sysroot.tar
        |   +-- (extracted, normalized sysroot tree)
        +-- <arm64>/
        |   +-- ...
        +-- lock/
            +-- BUILD.bazel       (:update sh_binary)
            +-- <name>.lock
            +-- update.sh
```

The hub-as-single-repo shape (rather than hub-of-aliases) is required
because [`toolchains_llvm`] records the label's package path verbatim as
`--sysroot=` and does not re-resolve `alias()` rules when baking the flag.

### Deduplication

By default (`deduped = True`), tags with identical configuration share a
single materialized hub. The first tag in a dedup group becomes the
"canonical" hub (full download + extraction + normalization). Each
subsequent tag with the same configuration becomes an **alias hub**:
a small repo whose per-arch directories are **symlinks** pointing at
the canonical's extracted tree.

Symlinks (rather than `alias()` BUILD targets) are required because
[`toolchains_llvm`]'s `--sysroot=<label>` bakes the label's package
path verbatim: `--sysroot=external/<alias_repo>/<distro>/<v>/<arch>`.
Bazel needs real files at that on-disk path; `alias()` rules don't
satisfy that constraint, but symlinks do. The dedup is invisible to
consumers: both `@canonical//<...>:sysroot` and `@alias//<...>:sysroot`
work identically; only the on-disk footprint shrinks (one extracted
tree, N symlink farms).

The dedup key is every tag attr except `name`. Tags meant to dedup
should share the same `lock` label; different lock labels are part
of the dedup-key identity even if their contents match. Set
`deduped = False` on a tag to opt out (e.g., materializing the same
content twice for test isolation, or when the lockfile differs
intentionally).

### Lower-level building blocks

For consumers that materialize sysroot hubs programmatically rather than
through the `sysroots.apt(...)` tag (e.g. a module extension that produces
one hub per resolved package group), the `apt/` package also exports:

- `@sysroots//apt:hub_repo.bzl::hub_repo`: the repository rule that backs
  the tag class.
- `@sysroots//common:lock.bzl::lock`: `new`, `encode`, `decode`, `validate`
  helpers for the lockfile schema (and the schema's `LOCK_VERSION`
  constant).

The tag flow and direct-`hub_repo` flow share the same normalization
pipeline and codegen helpers (`//common:codegen.bzl`,
`//common:normalize.bzl`, `//common:extra_files.bzl`), so consumers can mix
the high-level tag with low-level programmatic instantiation in the same
module extension.

### Adding a new package manager

`sysroots.rpm(...)` and `sysroots.apk(...)` are reserved as future tag
classes. To add one:

1. Create `rpm/` (or `apk/`) alongside `apt/`.
2. Implement a `download_and_extract` for that archive format.
3. Implement a thin `resolve.bzl` wrapper around whatever package resolver
   you use.
4. Implement a per-pkg-manager `repo.bzl` that runs the same Tier-1
   normalizations from `//common:normalize.bzl`, applies its own
   `known_patches.bzl`, then `//common:extra_files.bzl` for Tier-2.
5. Add the tag class to `extension.bzl` (`sysroots.rpm = _rpm_tag`).

`//common:codegen.bzl`, `//common:lock.bzl` and `//common:archs.bzl` are
package-manager-agnostic and reusable.

## 📄 Docs

For more details about each component, check the module docstrings in:

- `//:extension.bzl`: the `sysroots` module extension.
- `//apt:tag.bzl`: the `sysroots.apt(...)` tag class attrs.
- `//apt/private:repo.bzl`: the hub repository rule.
- `//common:normalize.bzl`: Tier-1 normalization rationale.
- `//common:extra_files.bzl`: Tier-2 injection.

## 💡 Contributing

Please feel free to open [issues] and [PRs], contributions are always
welcome!

[Bzlmod]: https://bazel.build/external/migration
[PRs]: ../../pulls
[`archive_override`]: https://bazel.build/rules/lib/globals/module#archive_override
[`rules_distroless`]: https://github.com/GoogleContainerTools/rules_distroless
[`toolchains_llvm`]: https://github.com/bazel-contrib/toolchains_llvm
[issues]: ../../issues
[non-registry override]: https://bazel.build/external/module#non-registry_overrides
