# `//toolchains/python`

A hermetic Python toolchain materialized from a single Debian apt snapshot via
`//sysroots:apt`, mirroring `//toolchains/perl`.

## Why a custom sysroot toolchain (not `rules_python`)

Python is a *dual* dependency for a PostgreSQL build, and version-coupled:

- **build-time interpreter**: meson resolves `find_program('python3')` and runs
  `import('python').find_installation(python.path())` to configure plpython, and
  PostgreSQL's build scripts run under it.
- **runtime ABI target**: `plpython` links `libpython`, so the interpreter meson
  configures against and the `libpython` / `python-<ver>-embed.pc` the per-PG
  sysroot ships must be the same MAJOR.MINOR.

A relocatable build-tool interpreter (`rules_python` / python-build-standalone)
does not track the Debian release, so on a release bump meson would configure
plpython against the wrong version (`python-3.11-embed.pc` not found when the
sysroot ships `3.13`). Sourcing the interpreter from `@python_sysroot` at the
release profile's snapshot makes the two agree by construction, exactly like
`@perl_sysroot` for plperl and the Debian LLVM toolchain for JIT.

`rules_python` is still used, but only as the version-irrelevant interpreter that
runs rules_foreign_cc's meson `py_binary`; nothing in this repo's build logic
references it.

## Layout

- `debian<release>.json`: the apt package manifest (`python3`, `python3-dev`),
  one per kept Debian release.
- `python_toolchain.bzl`: `python_toolchain` (the generic `sysroot_tool`),
  `current_python_toolchain` resolver, and the `python_toolchains()` matrix
  macro keyed on `release().python_version`.
- `locks/python_sysroot.lock`: the resolved apt closure.

See `//toolchains/perl/README.md` for the worked-example rationale of the shared
`sysroot_tool` machinery.
