# `sysroots/examples`

Self-contained workspace demonstrating both `//sysroots` consumption modes.

## Examples

- [`llvm_sysroot/`](llvm_sysroot/BUILD.bazel): `sysroots.apt(...)` +
  `llvm.sysroot(label=...)` from [`toolchains_llvm`]. A `cc_binary`
  (`:hello`) compiles and links a small C program against the hermetic
  Debian 12 sysroot. Demonstrates **filegroup mode**: `toolchains_llvm`
  records the label's package path verbatim as `--sysroot=`.

- [`buildtime_sysroot/`](buildtime_sysroot/BUILD.bazel):
  `sysroots.apt(...)` + a `genrule` that extracts `:sysroot.tar` at action
  time and reads files out of the extracted tree. Demonstrates **tar
  mode**: the consumer gets a writable, per-action copy of the normalized
  sysroot, including filenames Bazel can't represent as labels.

## Run

```sh
bazel test //...
```

Builds both examples end-to-end and asserts they compile / extract
correctly.

## Refresh lockfiles

If you bump the snapshot pin in `MODULE.bazel` or change the package list
of either tag, regenerate the corresponding lockfile:

```sh
bazel run @llvm_sysroot//debian/12/lock:update
bazel run @buildtime_sysroot//debian/12/lock:update
```

[`toolchains_llvm`]: https://github.com/bazel-contrib/toolchains_llvm
