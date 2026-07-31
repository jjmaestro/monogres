# Development

Monobot is built with [Quarkus](https://quarkus.io/) and Java 21.

Bazel is the whole build. The module lives in this directory and is independent
of the one under `build/`: it has its own `MODULE.bazel` and `.bazelrc`, and
knows nothing about the extension build. Run Bazel from `monobot/`, not from
the repository root.

```sh
cd monobot
bazel build //:monobot          # fast-jar under bazel-bin/monobot-quarkus-app
bazel run //:monobot_dev        # dev mode with hot reload and the Dev UI
bazel test //...                # compile, lint and unit tests
./bazel-bin/monobot_launcher.sh # run the built application
```

## Prerequisites

Bazel, and nothing else. The JDK, the formatter and the linter are all
downloaded and checksummed by `MODULE.bazel`, so none of them depend on what is
installed on the machine. The repository dev shell pins Bazel itself:

```sh
nix develop
```

## Dev mode

```sh
configDir=/path/to/config \
workdir=/tmp/monobot \
monogresRepo=/path/to/monogres \
  bazel run //:monobot_dev
```

## Packaging

`bazel build //:monobot` produces a fast-jar, not an uber-jar: the application
is in `bazel-bin/monobot-quarkus-app/quarkus-run.jar` with its dependencies
alongside in `lib/`. Run it with `./bazel-bin/monobot_launcher.sh`, which sets
the classpath up for you.

A native executable is not wired up. `rules_quarkus` supports one through
`quarkus_native_app` and `quarkus_native_container_app`; nothing here declares
either yet.

## Dependencies

Dependencies are pinned in `maven_install.json`. Only *runtime* artifacts are
declared in `MODULE.bazel`; Quarkus deployment artifacts are resolved from them
by reading each jar's `META-INF/quarkus-extension.properties`. After changing
`maven.install`, re-pin:

```sh
REPIN=1 bazel run @maven//:pin
```

## Toolchains

The JDK is `remotejdk_21`, downloaded and checksummed by `rules_java`. The
language level is declared in `.bazelrc` and nowhere else.

Nothing here compiles C++, but `java_binary` still needs C++ toolchain
*resolution* to succeed for its optional native launcher. `//toolchains`
registers an empty stub for that: analysis succeeds, and anything that actually
tries to compile C++ fails loudly rather than silently reaching for a host
compiler.

## Quarkus version

`rules_quarkus` supports only the exact Quarkus versions it ships support for,
because augmentation emits bytecode tied to the patch version. Upgrading
Quarkus therefore means waiting for `rules_quarkus` to support the target
version.

## Format and lint

Three tools, and you do not normally run any of them by hand. Two pre-commit
hooks cover the lot: `monobot-format` on a commit touching Java, then
`monobot-test` on a commit touching anything under `monobot/`.

```sh
bazel run //tools/lint:format        # rewrite files in place
bazel run //tools/lint:format.check  # fail instead of rewriting
bazel test //...                     # everything else
```

`monobot-format` runs the first of those, so a commit that needs reformatting
gets reformatted and then fails, leaving the changes to re-stage. `format.check`
is the same tool in reporting mode, for checking without touching the tree.

`format` is [google-java-format](https://github.com/google/google-java-format),
which also sorts imports and drops unused ones. Error Prone runs inside every
javac action, so a compile is what catches the bug patterns. Checkstyle runs as
an aspect over `java_library` and reports as an ordinary test failure. That is
why the second hook is `bazel test //...` rather than a lint command: it
compiles, which is what runs Error Prone.

Checkstyle uses the `google_checks.xml` ruleset that ships inside the
checkstyle jar, extracted at build time rather than copied into this
repository, so upgrading checkstyle brings its rule changes along unmodified.
Deviations from it live in `.checkstyle-suppressions.xml`. See
`tools/lint/lint.bzl` for how the three fit together.

## Tests

`RepoConfigSerializationTest` pins repo.json's serialized shape against a
golden. It uses plain JUnit.

`FetchPipelineTest` drives the whole pipeline, Scan through Fetch to the written
file, with the two network calls replaced: `TagLister` returns fixed tags and
`SourceArchive` writes a tarball the test generates instead of downloading one.
The archive is built rather than committed, with tar and gzip timestamps pinned
so its sha256 is reproducible and the digest in the golden is derived from real
bytes.

A single `quarkus_test` target covers the whole suite: it is the JUnit console
launcher on an augmented classpath, so plain tests and `@QuarkusTest` ones run
under the same rule.
