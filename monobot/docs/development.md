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

## Architectures

monobot builds for `amd64` and `arm64`. `//platforms:targets.bzl` is the single
source of truth for that list and for the facts derived from it: the
`ARCH_CPU` mapping, the `//platforms:is_linux_<arch>` config settings, the
`//platforms:linux_<arch>` platforms, and the `arch_select()` helper that keys a
`select()` on them. Nothing else in the tree defines its own architecture list.
The naming follows the module under `build/`: ARCH is the Debian name (`amd64`),
CPU is the machine name (`x86_64`).

Only `//:monobot_native` differs between the two. Everything else monobot
produces is a jar, and a jar is the same bytes everywhere.

```sh
bazel build //...                       # for the machine you are on
bazel build --config=linux-arm64 //...  # for arm64
```

Left alone, Bazel builds for the host, which is what you want when building
natively on either architecture. Naming a config selects the platform and puts
that architecture's cc toolchain first in resolution.

## Native executable

```sh
bazel build //:monobot_native   # bazel-bin/monobot_native
bazel run //:monobot_native
```

This is the one target that pulls a C toolchain into the build. GraalVM emits
object code and then links it, so `//:monobot_native` needs a compiler even
though no target here has a C source file. Both halves are pinned: GraalVM
comes from `rules_graalvm` and clang from `toolchains_llvm`, and the headers
and libc they link against come from a checksummed sysroot, built by
`//toolchains/sysroot:sysroot.bzl`, rather than from the machine.

The native-image arguments are split by what they describe. Those that follow
from the application's dependencies are in `application.properties`, which holds
for every architecture. Those that describe the libc and the link are
`native_build_args` on `//:monobot`, because they do not: a properties file is a
resource, fixed when the jar is built, so it cannot `select()` on the platform.

Expect the first build to be slow. It downloads GraalVM and LLVM, and
native-image itself takes minutes and a few GB of RAM.

### What each architecture produces

The two are not linked the same way, and the difference is forced by what
GraalVM supports rather than chosen.

**amd64 is fully static**: no ELF interpreter, no `DT_NEEDED` entries, so it
runs on any amd64 Linux regardless of what is installed there. Verified on
NixOS, Debian, Alpine and busybox from the one build. native-image allows
`--static` only against musl, so the sysroot is musl, assembled from Alpine
packages. It carries a static zlib as well as musl itself, because GraalVM links
`-lz` and a glibc zlib cannot go into a musl binary. Alpine supplies both
already built against musl, and `.apk` files are gzipped tarballs, so unpacking
them needs no Alpine tooling.

**arm64 is glibc**, built with `--static-nolibc`, which links everything except
the libc. Static linking is not available on this architecture at all, and the
gap is narrower than it looks. GraalVM's own musl C layer *is* built for
aarch64; what is missing is the static JDK libraries, which come from
[labs-openjdk](https://github.com/graalvm/labs-openjdk-21) and are built against
musl for `linux-amd64` only:

```console
ls <graalvm-amd64>/lib/svm/clibraries/linux-amd64      # glibc  musl
ls <graalvm-aarch64>/lib/svm/clibraries/linux-aarch64  # glibc  musl
ls <graalvm-amd64>/lib/static/linux-amd64              # glibc  musl
ls <graalvm-aarch64>/lib/static/linux-aarch64          # glibc
```

Those 80-odd archives are needed by every build, not just static ones, so on
arm64 no musl build is possible at all, and `--static` is rejected outright
against glibc. This is upstream's position rather than a local misconfiguration:
the prerequisite for a static executable is [documented][static-guide] as "Linux
x64", the musl toolchain Oracle publishes is `linux-amd64`, and Oracle's answer
on [#10375][] is that "static linking is not supported on Linux AArch64".
[#4645][], which asks for exactly these libraries, was closed as not planned.
Support is intended: on [#9490][] a maintainer said in July 2025 that there are
"plans to add support for static linking on linux/aarch64. Not in JDK 25, but
hopefully soon." GraalVM 25 is what this builds with, so not yet.

[static-guide]: https://www.graalvm.org/latest/reference-manual/native-image/guides/build-static-executables/
[#4645]: https://github.com/oracle/graal/issues/4645
[#9490]: https://github.com/oracle/graal/issues/9490
[#10375]: https://github.com/oracle/graal/issues/10375

The result depends on glibc and nothing else. Portability comes from the
sysroot's age rather than from static linking: it is Debian stretch, whose glibc
is 2.24, and glibc is backwards compatible, so the binary runs against anything
newer. On a distribution that keeps its loader in a store path, that loader has
to be reachable at `/lib/ld-linux-aarch64.so.1`; NixOS does this through
`nix-ld`. Revisit `--static` for arm64 when a GraalVM release ships
`lib/static/linux-aarch64/musl`.

Making the two symmetric means moving amd64 to glibc, not arm64 to musl: point
its sysroot at `debian_stretch_amd64_sysroot.tar.xz`, add `linux-x86_64` to
`cxx_include_layout`, and replace its `native_build_args` branch with
`--static-nolibc`. That costs the fully static binary, and is worth it only if
something needs `dlopen`, NSS, or a glibc-only library, none of which musl
supports the way glibc does.

Two consequences of linking with clang rather than gcc, both in the amd64
branch of `native_build_args`. `--rtlib=compiler-rt --unwindlib=none`, because
otherwise clang reaches for gcc's `crtbeginT.o`, `-lgcc` and `-lgcc_eh`, and
they have to be on the compiler and the linker both because the early "query
code" step passes only `-H:CCompilerOption` through. And no `--target=...-musl`,
because the prebuilt LLVM ships compiler-rt only under
`x86_64-unknown-linux-gnu` and a musl triple sends clang to a directory that
does not exist. The triple only selects search paths; the sysroot is what
actually supplies musl.

arm64 needs `-H:-CheckToolchain` for a related reason. Before compiling
anything, native-image runs the compiler with `-v` and identifies it by scanning
the output, and that scanner does not accept this one: the only architecture its
Linux branch knows by name is `x86_64`, and against a glibc sysroot clang also
reports the GCC installation the sysroot bundles, which the musl one does not
have. native-image names the option itself when it refuses. The check is a
heuristic and the toolchain behind it is sound, since the same clang and sysroot
go on to compile and link a working aarch64 binary.

The prebuilt LLVM is not self-contained. `clang`, `ld.lld` and `llvm-ar` each
need `libz.so.1`, `libzstd.so.1`, `libstdc++.so.6` and `libgcc_s.so.1` from the
machine, and `ld.lld` additionally needs `libxml2.so.2`. On NixOS the dev shell
supplies them; `flake.nix` pins libxml2 separately because unstable carries
2.15, which renamed the soname to `libxml2.so.16`. On a Debian-family machine,
`libxml2 libstdc++6 zlib1g libzstd1` covers it.

### Building the native executable for the other architecture

`--config=linux-arm64` cross-compiles almost everything. The jars build
anywhere, and Bazel resolves the arm64 cc toolchain and sysroot correctly. Two
targets still need an arm64 host, for unrelated reasons.

`//:monobot_native`, because native-image has to run on the architecture it is
building for: on an amd64 host it fails in the C query step. And `//:test`,
because the Quarkus model assembly runs the *target* JDK rather than the exec
one, so the action tries to execute an aarch64 `java` on the host and exits
255. That is a `rules_quarkus` bug rather than something to configure here,
and it costs little, since a test built for another architecture is not one
this machine could run anyway.

So build it on an arm64 machine, or in an arm64 container. With QEMU registered,
the emulated route works from an amd64 host and is very slow but needs nothing
else:

```sh
V=8.4.2
U=https://github.com/bazelbuild/bazel/releases/download

docker run --rm --platform linux/arm64 -v "$PWD:/src" -w /src debian:trixie \
  bash -c "
    apt-get update &&
    apt-get install -y curl zip unzip openjdk-21-jdk-headless &&
    curl -fsSLo /usr/local/bin/bazel $U/$V/bazel-$V-linux-arm64 &&
    chmod +x /usr/local/bin/bazel &&
    bazel build --symlink_prefix=/ //:monobot_native
  "
```

`rules_graalvm` and `toolchains_llvm` both pick their distribution from the
machine they run on, so nothing needs configuring for this: the container gets
the aarch64 GraalVM and the aarch64 LLVM on its own.

### Why native-image is not cross-compiled

native-image does have a target selector, `--target=linux-aarch64`, and it does
work: an aarch64 binary can be produced on an amd64 host, and it runs. It is not
used here because getting there costs three things, and the result is not the
same binary a native build produces.

- **A merged JAVA_HOME.** An amd64 distribution carries `lib/static/linux-amd64`
  and `lib/svm/clibraries/linux-amd64` and no other architecture, and the
  built-in search paths are validated even when `-H:CLibraryPath` names others,
  so the two distributions have to be merged into one tree rather than pointed
  at.
- **A C Annotation Processor cache.** Cross builds force `-H:+UseCAPCache`,
  because the query step compiles C and runs it, which a foreign architecture
  cannot do. No cache ships with the distribution, so one has to be generated on
  the target architecture and committed. It is not a per-platform artifact:
  monobot's cache carries a `Substitutions_NativeInfoDirectives` entry that a
  hello-world one does not, contributed by the native substitutions its
  dependencies register. Adding an extension that declares `@CContext`
  directives silently invalidates it, and the resulting failure is an
  unexplained abort in `[1/8] Initializing`.
- **`-H:-CheckToolchain` and `-H:-ForeignAPISupport`.** The first waves off the
  host/target architecture mismatch. The second is not a preference: the
  Foreign Function and Memory feature picks its ABI from the host, then hands it
  the target's assembler, and the build dies with
  `SubstrateAArch64MacroAssembler cannot be cast to AMD64MacroAssembler` inside
  `ABIs$X86_64.generateTrampolineTemplate`. Disabling FFM is the only way past
  it, and that makes the cross-built binary strictly less capable than a
  natively built one.

The emulated container above uses the supported path and produces the real
artifact, which is why it is the documented route.

It is worth assembling anyway when something arm64-specific needs checking,
because the speed difference is not marginal: cross-compiling this application
takes about 45 seconds against half an hour or more emulated. Run it by hand on
the `native-sources` tree the amd64 build already produces, under
`bazel-bin/monobot_native-native-sources`, since augmentation output is
architecture-independent. Regenerate the cache first, on the target
architecture, with `-H:+NewCAPCache -H:CAPCacheDir=<dir> -H:+ExitAfterCAPCache`,
which runs only the query step and so costs a minute or two rather than a whole
image. That is how the arm64 link options here were settled.

### Why GraalVM 25

native-image refuses to initialize a class while building the image if the jar
that ships it asked for run-time initialization, and the image Quarkus 3.33
describes cannot satisfy that rule on older builders. The one with no
configuration answer is:

```text
io.smallrye.common.net.HostName ... was requested to be initialized at run
time (from feature io.quarkus.runner.Feature.beforeAnalysis)
```

`org.jboss.logmanager.ExtLogRecord`'s constructor reads the host name, so *any*
log record built during image construction initializes `HostName`, while
Quarkus's own feature registers that same class for run-time initialization.
Two independent triggers exist -- the JDK emits a `jdk.event.security` record
for every certificate it parses and GraalVM parses the whole truststore during
setup, and netty logs a line when it picks its logging backend from
`AbstractChannel`'s static initializer -- so there is no single trigger to
suppress. Log levels do not help either: Quarkus's `InitialConfigurator`
hardcodes the root logger to `Level.ALL`.

GraalVM 25 does not have the problem. 23.1 does, in both the CE and Mandrel
builds, which is why `MODULE.bazel` pins `rules_graalvm` past its last release:
the newest version in the BCR cannot express a GraalVM this new. Quarkus 3.33's
own default builder image is Mandrel 25, so this is the combination upstream
tests.

The five `--initialize-at-run-time` entries in `application.properties` are
still required on 25; they are what clears the netty and vert.x complaints.

Note that this needs GraalVM CE specifically. Mandrel, which Quarkus ships as
its default builder image, rejects musl outright with "target libc: musl is not
supported on your platform".

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

The C toolchain is clang from `toolchains_llvm` plus a pinned sysroot, and
exists only for the native build above. `.bazelrc` sets
`BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1` so Bazel does not probe the host for a
compiler first: repository rules run with a scrubbed `PATH`, so that probe
fails even on machines that have one.

One clang serves both architectures, because an LLVM release emits code for
every target it was built with. `llvm.toolchain` names where clang runs and the
two `llvm.sysroot` tags name what it compiles for, so `@llvm_toolchain//:all`
registers one cc toolchain per architecture and `--platforms` chooses.

The sysroot is not optional. An LLVM release ships clang, lld and libc++, but
no libc: no `stdio.h`, no `crt1.o`, no `libc.so`. Clang would look for those
under `/usr/include` and `/usr/lib`, which on some distributions means linking
against whatever the build machine happened to have, and on others means
finding nothing at all. There is one per architecture, since a sysroot is the
target's libc.

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

Tests are split by what they can see, not by what language they are written in.
The root package holds the ones compiled against the code, and `//tests` holds
the ones that run a built application and know nothing of its internals.

```sh
bazel test //...            # everything in the default gate
bazel test //tests/...      # only the ones that run a built application
```

```text
src/main/java/…                      the application
src/test/java/…                      unit tests, same packages as main
src/it/java/…                        integration tests, named *IT

//:test              //:checkstyle_test         compiled against the code
//tests:e2e_offline  //tests:e2e_offline_native run a built application
//tests:e2e_golden   //tests:e2e_golden_native
//tests:it_native
```

Java puts tests in a source root of their own with the package names mirrored,
which is what lets a test reach a package-private member, and what keeps test
code out of the jar. `src/it/java` is separate again because an integration test
runs against the packaged application rather than a classpath.

`//:it_lib` is the one target whose placement is forced rather than chosen: it
compiles `src/it/java`, a glob cannot cross a package boundary, and there is no
BUILD file under `src/`. The test that runs those classes lives in `//tests`
with the rest.

### Compiled against the code

`RepoConfigSerializationTest` pins repo.json's serialized shape against a
golden. It uses plain JUnit.

`FetchPipelineTest` drives the whole pipeline, Scan through Fetch to the written
file, with the two network calls replaced: `TagLister` returns fixed tags and
`SourceArchive` writes a tarball the test generates instead of downloading one.
The archive is built rather than committed, with tar and gzip timestamps pinned
so its sha256 is reproducible and the digest in the golden is derived from real
bytes.

A single `quarkus_test` target covers both: it is the JUnit console launcher on
an augmented classpath, so plain tests and `@QuarkusTest` ones run under the
same rule.

### Run against a built application

None of the above can see a packaging fault. `//:monobot_native` is an image,
and native-image keeps only the members it can prove are reachable; every type
monobot exchanges as JSON is reached only through Jackson, so an image that
drops their reflection starts cleanly and then cannot read a thing. Running the
artifact is the only way to find that, which is why these exist.

`//tests:e2e.bzl` builds them from one macro, parameterised by which application
to run. `//:monobot` and `//:monobot_native` are both executable and read the
same three settings from the environment, so each check runs against either, and
the pair says which of the two layers a failure is in.

Two shapes:

- **offline**, in the default gate. Points at a host that does not resolve, and
  asserts on a URL that appears nowhere but inside the config, so only a run that
  deserialized it can produce it. Everything a packaging fault touches has
  already happened by the time the fetch fails. Costs a second.
- **golden**, tagged out of the default gate. A real scan of one extension
  compared byte for byte, so it needs the network:
  `bazel test //tests:e2e_golden_native`. noset is the subject because it is
  small, three versions, and no longer released, so the golden does not go stale
  behind us.

`//tests:it_native` asks the offline question again in Java, with
`@QuarkusMainIntegrationTest` launching the binary and `LaunchResult` carrying
its output. It is the same check in the idiom Quarkus users expect, and it is
what to copy when a test needs real Java rather than a shell. It builds a native
image, so it is tagged `manual`. Note that the rule behind it has no `data`
attribute, so its fixture is written at run time rather than taken from a file.

Bazel cannot make one target depend on another target's test result, so the JVM
check is also expressed as a build action, `//tests:jvm_gate`, whose output file
is an input of the native tests. An application that cannot read its own config
on the JVM therefore fails before anything spends minutes building an image.

When changing any of this, check the test can still fail: revert the thing it
guards, watch it go red, then put it back. A test that has never failed has not
been shown to test anything.
