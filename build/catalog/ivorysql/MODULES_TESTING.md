# IvorySQL `src/test/modules` testing (DEFERRED, known gap)

**Status: deferred (2026-06).** All 43 `src/test/modules` suites are excluded
from the ivory lane via `metadata.test_overrides` (`"exclude": true`) so the
lane is green. This is a pre-existing, ivory-specific test-variant staging bug,
unrelated to the oracle deferral or the gb18030 fix. This doc is a debugging
handoff: the symptom, the confirmed root cause, the open question, and the fix.

## Symptom

Running the full ivory lane (`bazel test @ivory//5.0/full/tests/...`), every
`test/modules/*` suite fails (68 targets) with, for example:

```text
CREATE EXTENSION test_rbtree;
ERROR:  extension "test_rbtree" is not available
...
SELECT test_rb_tree(10000);
ERROR:  function test_rb_tree(integer) does not exist
```

`typcache` similarly fails on `injection_points_detach(...) does not exist`. The
cluster comes up and runs; it just cannot find the module extensions.

## Confirmed root cause: test-variant staging-prefix mismatch

The module `.so`/`.control` ARE built and present in the ivory test-variant tar,
but at a prefix the ivory cluster does not search. Where each artifact lands:

```text
artifact                ivory test tar               postgres test tar
regress.so   (works)    lib/postgresql/              lib/postgresql/
plpgsql.control (core)  share/postgresql/extension/  share/extension/
test_rbtree.so (fails)  lib/                         lib/
test_rbtree.control     share/extension/             share/extension/
```

The ivory cluster's `sharedir` is `share/postgresql` (that is where its core
`plpgsql.control` lives and is found), but the module `.control` files land in bare
`share/extension/`. So `CREATE EXTENSION test_rbtree` looks in
`share/postgresql/extension/` and does not find it. The harness `--dlpath` is
`lib/postgresql` while the module `.so` are in bare `lib/`, the same mismatch on
the library side.

**Postgres is unaffected** and its identical `test/modules` suites PASS (for
example `@pg//17.6/full/tests/test/modules/test_rbtree:test_rbtree` is green): the
postgres test variant uses the bare `share/` + `lib/` layout throughout (its
`plpgsql.control` is also in `share/extension/`), so the modules' bare layout
matches its cluster's sharedir. IvorySQL's test variant instead uses the full
`share/postgresql` + `lib/postgresql` layout for the core, but the `test/modules`
install step stages to the bare layout. Within ivory, core and modules disagree.

## Open question (start here)

Why does ivory's test variant relocate the core to `share/postgresql` +
`lib/postgresql` while the `test/modules` install uses bare `share/` + `lib/` (and
why does postgres's test variant use bare throughout)? The fix is to make them
consistent. Two angles:

- Make the `test/modules` install in the test variant honor the flavor's prefix
  (ivory modules to `share/postgresql/extension` + `lib/postgresql`), or
- Make the ivory test variant's core relocation use the same bare layout postgres
  uses, so the existing bare module install matches.

Either way, after the fix `CREATE EXTENSION` must resolve the module `.control`
under the cluster's actual `sharedir`, and `--dlpath` must point where the module
`.so` actually are.

## Where to look

- The test-variant overlay and module install: the test-variant path in
  `build/monoext/private/base/pg_build.bzl`, and how it installs `src/test/modules`.
- The harness `--dlpath`/`--bindir` derivation:
  `build/monoext/private/test/regress_runner.sh` and
  `build/monoext/private/test/suites.bzl` (`_subtree_rlocs`, the modules tree).
- The crux is the prefix/relocation difference: compare the ivory vs postgres
  test-variant install trees under
  `bazel-out/.../+monoext+<hub>/<v>/full/test/tar`.

## Reproduce

```sh
# ivory: all test/modules fail
bazel test @ivory//5.0/full/tests/test/modules/... --test_output=errors
# postgres: the same suite passes (isolates the ivory gap)
bazel test @pg//17.6/full/tests/test/modules/test_rbtree:test_rbtree
# inspect the layout mismatch (look for test_rbtree.control vs plpgsql.control)
find <ivory-test-tar> -name 'test_rbtree.control' -o -name 'plpgsql.control'
```

## To re-enable

Remove the `test/modules` `"exclude": true` entries from
`catalog/ivorysql/repo.json` `metadata.test_overrides` (everything from `brin`
through `xid_wraparound`) once the staging-prefix is fixed, then
`bazel test @ivory//5.0/full/tests/test/modules/...` should be green.
