# openHalo hermetic test lane

**Status (2026-06-14): 125/125 pass.** The whole lane is green:
`bazel test @openhalo//1beta1/full/tests/...` reports `125 out of 125 tests` pass.
The non-TAP lane (regress, isolation, pl*, contrib) and the Perl TAP lane are
both green; 5 genuine-openHalo residuals are TAP-skipped (below) and the heavy
multi-cluster TAP suites carry a CPU reservation so the full lane does not flake
them under contention.

## Two openHalo defaults the upstream TAP suite assumes

openHalo (PG14.18, MySQL-wire-compatible) diverges from stock PostgreSQL in two
defaults that the upstream Perl TAP framework (PostgresNode) -- which openHalo
does not run (no CI) -- depends on:

1. **Default admin database is `halo0root`, not `postgres`** (initdb.c
   make_postgres; carried through the backend, the client tools, and the C
   regress driver pg_regress.c). PostgresNode connects to `postgres` by default
   and the .pl tests hard-code it in SQL + connection strings.
2. **csvlog by default**: postgresql.conf.sample ships
   `log_destination='csvlog'` + `logging_collector=on` uncommented, so server
   logs land in `pgdata/diag/*.csv` while the framework greps the stderr logfile
   (`$node->logfile`).

Both are handled, test-only, in
`patches/0001-1beta1-tap-adapt-postgresnode-for-openhalo.patch` (PostgresNode::init):
recreate the stock `postgres` db (single-user mode, with the standard COMMENT
stock initdb make_postgres produces) + restore stderr logging in the node config.
The upstream tests then run verbatim; production defaults (halo0root, csvlog) are
unchanged (src/test/perl is not installed). Rejected alternatives: a
postgres->halo0root connstr redirect (only 70/125 -- the suite hard-codes
postgres in SQL/connstr text beyond connstr()), and a full suite rename (forks
the upstream tests). Pigsty's `pgsty/openHalo` ec879535 reverts
halo0root->postgres across 17 PRODUCT files; we keep the product faithful.

## Build: perl from @perl_sysroot

The make build sources perl from the @perl_sysroot toolchain + the
Config_overrides shim, exactly like the meson path (pg_build.bzl) -- one perl
mechanism across both build systems. IPC::Run for the `configure
--enable-tap-tests` gate comes from @perl_sysroot, so per-PG buildtime
libipc-run-perl is dropped.

## TAP-skipped residuals

5 genuine-openHalo or necessary-shim-collateral .pl tests, each TAP-skipped via
a `tap_skip` entry in `metadata.test_overrides` (per slug, keyed by .pl name):

```text
pgbench/002_pgbench_no_server   genuine: --help/--version rebranded Halo
pg_dump/002_pg_dump             shim: pg_dumpall dumps the recreated postgres db
pg_dump/010_dump_connstr        shim (excludes halo0root, not postgres)
pg_ctl/004_logrotate            csvlog-collector domain (haloserver csv)
pg_rewind/002_databases         openHalo behavioural divergence
```

`tap_skip` is a catalog-driven per-.pl skip in `suites.bzl::_suite_test`, read off
`eff_override.get("tap_skip")` and emitted as the same `--skip-reason` TAP
skip-all the hardcoded `_TAP_REQUIRES_TERMINAL` block uses. The reason rides the
`sh_test` `args`, which Bazel re-tokenizes with Bourne-shell quoting, so a reason
carries no apostrophe / quote. The same mechanism applies to babelfish.

## Contention floor for the heavy TAP suites

The heavy multi-cluster TAP suites (recovery, pg_rewind, pg_basebackup, pg_ctl,
pg_verifybackup, subscription) initdb and start several postgres clusters per
.pl. Left at the default 1-core estimate the full lane co-schedules ~18 of them
and the cluster-start storm saturates the CPU, so a `pg_ctl start` wait loop or
a recovery startup times out (e.g. `pg_ctl/001_start_stop`,
`recovery/008_fsm_truncation`, `pg_basebackup/010_pg_basebackup`) even though each
passes alone. They size `large` (a wide timeout) AND carry a `cpu:4` tag
(`_BIG_SUITES` + the TAP kind in `suites.bzl`), so Bazel reserves 4 cores per test
and caps how many run at once, which clears the start races. The same levers apply
to babelfish.
