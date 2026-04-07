# Perl toolchain

Custom Bazel toolchain providing a hermetic Perl interpreter plus its
matching `libperl` headers and shared library, all sourced from a
single Debian snapshot via the `//sysroots:apt` extension.

Consumed by `//monoext/private/base:pg_build` to build Postgres's
`plperl` extension.

## Why a custom toolchain (not `rules_perl`)

Postgres's `plperl` build imposes a hard **three-way ABI lockstep**:

1. The Perl **interpreter** running `plperl_opmask.pl` at configure time
2. The libperl **headers** (`perl.h`) and `.so` linked into `plperl.so`
3. The `libperl.so.<MAJOR.MINOR>` loaded at production **runtime**

All three MUST be the same Perl version. `plperl_opmask.pl` uses the
running Perl's `Opcode` module to enumerate opcodes; the result is
compiled into `plperl.c` as symbolic C identifiers (`OP_NULL`,
`OP_PADSV_STORE`, ...) that get resolved from `<perl.h>`. If the
running Perl knows `OP_PADSV_STORE` (added in Perl 5.38) and emits it
into the generated `plperl_opmask.h`, but the linked `<perl.h>` is
from Debian's libperl 5.36, the compile fails with `use of undeclared
identifier 'OP_PADSV_STORE'` (and 5 sibling errors for the other
5.38-era opcodes).

`rules_perl` 1.1.1 ships skaji/relocatable-perl 5.40, which mixes
badly with Debian 12's libperl 5.36. The interpreter version is not
aligned with the link / runtime ABI. The mismatch is structural; no
shim or Config monkey-patch can paper over it because the opcode
header gets baked into the C source before linking.

The full investigation lives in `/REPORT-Postgres_build_and_Perl.md`
at the repo root.

## Mechanism

`MODULE.bazel` materializes the Perl sysroot via the `//sysroots:apt`
extension:

```python
sysroots = use_extension("@sysroots//:extension.bzl", "sysroots")
sysroots.apt(
    name = "perl_sysroot",
    lock = "//toolchains/perl/locks:perl_sysroot.lock",
    manifest = "//toolchains/perl:debian.json",
    snapshot = APT_SNAPSHOT,
)
use_repo(sysroots, "perl_sysroot")
```

This pulls the packages listed in `debian.json`:

- `perl-base`: interpreter binary + core modules (`Config`, `Opcode`,
  `ExtUtils::Embed`, `ExtUtils::ParseXS`, etc.)
- `libperl-dev`: `libperl.so` symlink + `perl.h` headers for
  compile/link
- `libperl5.36`: `libperl.so.5.36` runtime library

Transitive deps (`libc6`, `libcrypt1`, `perl-modules-5.36`, `dpkg`,
etc.) get resolved by the lockfile generator. The resolved set
materializes at `@perl_sysroot//debian/12/<arch>:sysroot`.

The interpreter, headers, and shared library all come from the same
Debian snapshot in lockstep. No ABI mismatch is possible.

## Layout

```text
build/toolchains/perl/
├── BUILD.bazel              # Per-arch aliases (:sysroot, :sysroot_tar)
├── README.md                # This file
├── debian.json              # Perl package manifest
└── locks/
    ├── BUILD.bazel          # Lockfile exports
    └── perl_sysroot.lock    # Resolved Debian Perl package set
```

## Regenerating the lockfile

The `sysroots.apt(...)` extension writes the resolved package set
into the lockfile. To regenerate after editing `debian.json` or
bumping the snapshot:

```sh
bazel run @perl_sysroot//debian/12/lock:update
```

This rewrites `locks/perl_sysroot.lock` in place.

## Per-PG-version flexibility

`build/catalog/postgres/repo.json` supports per-PG dep overrides via
the `"*"` selector in `deps.buildtime` and `deps.runtime`. The
toolchain composes with this mechanism: if a future PG version
requires Perl 5.38+ (e.g. when upstream tightens the
`plperl_opmask.pl` contract), declare a parallel
`sysroots.apt(name = "perl_sysroot_5_38", ...)` and select it from
the per-PG override slot. Each toolchain is internally consistent
within itself; the override slot is the toolchain identity.

## Bind-mount manifest interaction

The custom Perl toolchain does NOT directly drop the
`libcrypt.so.1` bind-mount; Debian's `perl` binary still
`NEEDED libcrypt.so.1`. libcrypt collapses as a side effect of
Phases B and C of the bind-mount manifest collapse (LLVM tarball
lib/ overlay + sysroot_setup.sh action-time symlinks), which
populate the chroot's standard library search paths from the
sysroot's `libcrypt1` package. See
`/home/jjmaestro/.claude/plans/logical-tumbling-donut.md` for the
phased rollout plan.
