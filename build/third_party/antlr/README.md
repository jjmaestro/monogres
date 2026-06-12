# `antlr_jar` — vendored ANTLR4 Java tool jar

A self-contained Bazel module that exposes the ANTLR4 Java tool jar
(`antlr-<version>-complete.jar`) as `@antlr_jar//:jar`. Used by downstream
flavors that ship an inline cmake project to codegen C++ parsers from `.g4`
grammars (currently consumed by the Babelfish flavor's `babelfishpg_tsql`
extension).

## Why not Bazel Central Registry?

The ANTLR4 **C++ runtime** is on BCR as
[`antlr4-cpp-runtime`](https://registry.bazel.build/modules/antlr4-cpp-runtime).
The **Java tool jar**, however, is not on BCR (as of this writing) — only the
C++ runtime is. Consumers that need the Java tool either pull the jar
directly via `http_file` or vendor it.

This module vendors the jar into a tiny self-contained Bazel module so
monogres (and any sibling project under the same workspace) can depend on
`@antlr_jar//:jar` without each project re-deriving the same `http_file` boilerplate.

## How to update the version

1. Update `_ANTLR_VERSION` in `antlr.bzl`.
2. Update `_ANTLR_JAR_SHA256` to match the new jar:

   ```sh
   curl -fsSL https://www.antlr.org/download/antlr-<NEW_VERSION>-complete.jar \
       | sha256sum
   ```

3. Update the version in this README.

## Publishing to BCR

This module is intentionally self-contained:

- Pinned `bazel_dep`s only (no `local_path_override`s).
- No dependencies on the monogres workspace.

To publish to BCR, follow the
[contribution guide](https://github.com/bazelbuild/bazel-central-registry/blob/main/docs/bcr-policies.md).
The module's `MODULE.bazel`, `BUILD.bazel`, and `antlr.bzl` files can be
uploaded as-is.
