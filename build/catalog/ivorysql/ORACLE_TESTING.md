# IvorySQL oracle-mode testing (DEFERRED)

**Status: deferred (2026-06).** The IvorySQL test lane (`@ivory`) covers the
PostgreSQL-mode test surface only. The oracle-mode test suites are intentionally
not pursued. Note this is a *test-suite* decision: the oracle **runtime** is fully
built by our (meson) build and works; only the oracle **tests** are deferred.

For the full analysis, evidence, and re-enablement options, see the companion
report `REPORT-ivory-oracle_testing.md` (kept outside the repo for future work).

## What runs today (green)

`@ivory//<v>/<opt>/tests/...` renders the meson-introspected, PG-mode surface,
identical in shape to the postgres flavor: core regress (`src/test/regress`),
isolation, TAP, and the PLs. On 5.0 these pass (regress 227/228, see the gb18030
note below; isolation + TAP green).

## What is deferred (not run)

The oracle-mode suites, which require an `initdb -m oracle` cluster:

- the main oracle regress suite (`src/oracle_test/regress`)
- the oracle contrib/PL suites: `ivorysql_ora`, `ora_btree_gin`, `ora_btree_gist`,
  `plisql`

These are exactly the suites upstream removed from the meson build in PR #1180.

## Why deferred

1. **Make-only by upstream design.** IvorySQL's `initdb` defaults to *oracle* mode;
   meson's shared test template is forced to `-m pg`, and PR #1180 (merged to
   master) *removed* the oracle test blocks from meson ("still available via
   make") because oracle-mode init conflicts with the PG-mode meson environment.
   So the meson introspection cannot enumerate the oracle suites, and wiring them
   in means undoing a deliberate, merged upstream decision.
2. **Fragile, immature harness.** The oracle suite runs through a *separate*
   `src/oracle_test/regress/pg_regress` with a dual-port bootstrap
   (`oraPort = port + 1`; the oracle SQL parser activates only on connections to
   the oracle listener port, `connmode == 'o'`). It does not bootstrap cleanly
   outside IvorySQL's native make + full-OS CI (the regression-DB / oracle-port
   handshake is ordering-sensitive). Open issue #1323 shows even
   `make oracle-check-world` skips most `oracle_test/modules`.
3. **Cost/benefit.** The oracle runtime is verified working on the meson-built
   artifact (the `number`/`varchar2`/oracle `date` types, the oracle parser:
   `nvl`, `dual`, empty-string->NULL, PL/iSQL functions, the `ivorysql_ora`
   extension). The marginal value of running the fragile full suite did not
   justify the effort relative to the rest of the work.

## How the deferral is implemented (and how to re-enable)

The oracle-mode suites are turned off in `repo.json`:

- the `metadata.test.oracle` block (the main oracle regress suite) is removed; and
- `metadata.test_overrides` marks the oracle contrib/PL suites `"exclude": true`
  (`ivorysql_ora`, `ora_btree_gin`, `ora_btree_gist`, `plisql`).

That yields a fully green PG-mode lane. To genuinely run the oracle suites later,
restore those entries with their oracle-mode config AND build IvorySQL's own oracle
`pg_regress` (meson already defines it in `src/oracle_test/regress/meson.build`,
just unwired), or add a lighter oracle-mode smoke test of the runtime. See the
report for both, with effort estimates.

## gb18030 note (the 227/228 residual)

The single regress residual is `opr_sanity` flagging a `gb18030_and_gbk` conversion
registered with no matching `.so` in the meson tree. PR #1180 *also* added that
conversion to `src/backend/utils/mb/conversion_procs/meson.build`; our 5.0 source
predates that fix. Backporting that one meson hunk closes the residual and is
independent of oracle testing.
