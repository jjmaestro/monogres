#!/bin/bash
# Tier-3 (non-hermetic) external suite placeholder.
#
# Some upstream extension suites are not hermetically runnable: citus's
# pg_regress_multi.pl drives several live clusters plus a mitmproxy/python
# stack, outside what the sandboxed lane provides. Such a suite is still
# declared (a `kind: manual` external decl) so it is queryable and tagged, but
# it has no hermetic runner and is meant to be run by hand, non-hermetically.
# Tagged `manual` + `non-hermetic` so `bazel test //...` skips it; an explicit
# invocation fails here on purpose, pointing at the manual path.
set -eu
suite="${1:-<suite>}"
echo "ERROR: external suite '${suite}' is tier-3 (non-hermetic): no hermetic runner." >&2
echo "       Run it by hand against a real cluster set; see the catalog test_ext note." >&2
exit 1
