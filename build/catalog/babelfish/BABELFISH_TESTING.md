# Babelfish hermetic test lane

**Status: green.** `bazel test @babelfish//4.0/full/tests/...` and
`@babelfish//5.1/full/tests/...` both pass in full (4.0: 163/163; 5.1: 186/186).
The non-TAP lane (regress, isolation, pl*, contrib) and the Perl TAP lane are
both green; no `tap_skip` residuals are needed beyond the two flavor-agnostic
controlling-terminal pty tests the harness already skips everywhere.

Babelfish is `postgresql_modified_for_babelfish` (a PostgreSQL fork that adds the
T-SQL/Babelfish backend hooks) plus the `babelfish_extensions` PGXS extensions.
It is built make-side (`pg_build_make`, with the ANTLR runtime +
`babelfishpg_tsql` overlay), 4.0 on a PG16.1 base and 5.1 on a PG17.4 base.

## Scope

Vanilla pg_regress + isolation + the PL languages + contrib + the Perl TAP
suites. The Babelfish-specific surfaces (T-SQL grammar, TDS wire protocol, JDBC)
are out of the hermetic scope, and the extensions that carry them are not run:

- `babelfishpg_tsql` and `babelfishpg_money` appear in the introspect as
  regress suites but are `exclude`d in `metadata.test_overrides`: their test
  trees live in the separate `babelfish_extensions` repo
  (`contrib/<ext>/test/`), merged into `contrib/` only inside the build action,
  so they are not present in the single source tree (`@babelfish//<v>/src:dir`)
  the harness reads.
- `babelfishpg_unit` ships no pg_regress suite at all: its Makefile declares
  `MODULE_big`/`EXTENSION`/`DATA` only (no `REGRESS`, no `test/sql`). It is a
  SQL unit-test *framework* extension other Babelfish tests drive over TDS, not
  a runnable pg_regress suite, so there is nothing to enumerate. It is installed
  (it shows up under `installed.contrib/babelfishpg_unit/` in the introspect)
  but contributes no test target.

## Three stock-PostgreSQL defaults Babelfish keeps (unlike openHalo)

The openHalo lane needed a PostgresNode adaptation patch because openHalo
diverges from stock PostgreSQL in two TAP-relevant defaults. Babelfish keeps all
three stock, so it needs no such patch:

1. **Default admin database is `postgres`.** `initdb.c make_postgres` runs the
   stock `CREATE DATABASE postgres` + the standard
   `COMMENT ON DATABASE postgres IS 'default administrative connection
   database'`. PostgresNode connects to `postgres` by default and the .pl tests
   hard-code it; this just works.
2. **Logging is stderr, collector off.** `postgresql.conf.sample` ships the
   stock `#log_destination = 'stderr'` + `#logging_collector = off` (both
   commented). Server logs land in the stderr logfile the framework greps
   (`$node->logfile`), so `log_contains` / `issues_sql_like` / `wait_for_log`
   see the lines directly. No csvlog force-stderr fix is needed.
3. **No tool rebranding.** `configure` keeps `PACKAGE_NAME='PostgreSQL'` and the
   version string (`17.4` for 5.1), so the `--version` / `--help` TAP assertions
   in pgbench / psql / the client tools pass unchanged.

The net effect is that Babelfish's vanilla-PostgreSQL test surface behaves like
stock PostgreSQL of the same base version; the Babelfish modifications are
additive backend hooks that do not perturb the upstream regress/isolation/TAP
suites.

## Build: perl + the PG17 backup tools

- **Perl from `@perl_sysroot`.** The make build sources perl from the
  `@perl_sysroot` toolchain + the `Config_overrides` shim, exactly like the
  meson path; IPC::Run for the `configure --enable-tap-tests` gate rides
  `@perl_sysroot`, so no buildtime `libipc-run-perl` is added (only `deps.test`,
  for the TAP runfiles).
- **PG17 backup tools need no gating on the make path.** The meson path captures
  a curated `out_binaries` list and gates `pg_combinebackup` / `pg_walsummary` /
  `pg_createsubscriber` (PG17 src/bin tools) on `pg_base_version`. The make path
  installs the whole tree via `make install-world-bin`, so those tools land in
  `bin/` natively on the PG17-base 5.1 build; their TAP suites
  (`pg_combinebackup`, `pg_walsummary`, `pg_basebackup/040_pg_createsubscriber`)
  render and pass with no change to `pg_build_make`.

## The one fix: stage `pg_bsd_indent` into `test_bin/`

The single pre-fix failure on both versions was
`tools/pg_bsd_indent/tap:001_pg_bsd_indent`: `pg_bsd_indent --version` reported
"command not found". `pg_bsd_indent` (src/tools/pg_bsd_indent) is `install:
false` upstream, so neither meson's `world` nor make's `install-world-bin`
installs it, yet its `t/001_pg_bsd_indent.pl` runs it by bare name on PATH. The
meson path already captures it into `test_bin/` (the `_TEST_MODULES_CAPTURE`
block in `pg_build.bzl`, alongside the libpq test helpers); the make path's
`stage_test_bin` (`pg_build_make.bzl`) staged only the libpq helpers.

`stage_test_bin` now also `make all`s `src/tools/pg_bsd_indent` and copies the
`pg_bsd_indent` binary into `test_bin/`, mirroring the meson capture. The harness
puts `test_bin/` on the TAP PATH, so the suite finds the tool. The change is in
the test-variant path (gated on `tap_tests=enabled`), so production builds are
unaffected; it is also a no-op for PG14-base flavors (openHalo), whose introspect
predates the PG16 `pg_bsd_indent` TAP test.

## TAP-skipped residuals

None Babelfish-specific. The two controlling-terminal pty tests
(`authentication/001_password`, `psql/010_tab_completion`) are skipped by the
flavor-agnostic `_TAP_REQUIRES_TERMINAL` block in `suites.bzl` (the hermetic
sandbox grants no controlling terminal); they are not Babelfish residuals.

The `tap_skip` mechanism (catalog-driven, per-.pl, under a suite's
`metadata.test_overrides` slug) is available if a genuine Babelfish divergence
surfaces on another option set, exactly as on openHalo. None is needed for the
`full` lane.

## Contention floor for the heavy TAP suites

The heavy multi-cluster TAP suites (recovery, pg_rewind, pg_basebackup, pg_ctl,
pg_verifybackup, subscription) carry the shared `cpu:4` reservation (the
`_BIG_SUITES` + TAP-kind path in `suites.bzl`) so the full lane does not
co-schedule a cluster-start storm that starves a `pg_ctl start` or recovery
startup into a flaky timeout. The same levers as openHalo; no Babelfish-specific
extension was required.
