#!/bin/bash
# shellcheck disable=SC2154,SC2250,SC2292
# Citus hermetic multi-cluster integration assertion.
#
# Invoked by regress_runner.sh --kind integration with NUM_CLUSTERS clusters
# live on 127.0.0.1: PGPORT_0 is the coordinator, PGPORT_1.. are workers, and
# PGPORTS is the space-separated list (citus is already in
# shared_preload_libraries). It builds a minimal Citus topology, distributes a
# table across the workers, and asserts cluster membership + distributed data
# under ON_ERROR_STOP. The exit code is the verdict; there is no golden output.
set -euo pipefail

coord="${PGPORT_0}"

psql_c() {  # psql_c <port> <sql> -> bare scalar (unaligned, tuples-only)
  psql -h 127.0.0.1 -p "$1" -U postgres -d postgres -v ON_ERROR_STOP=1 -At -c "$2"
}

echo "== CREATE EXTENSION citus on all ${NUM_CLUSTERS} clusters ==" >&2
for p in ${PGPORTS}; do
  psql_c "$p" "CREATE EXTENSION citus;"
done

echo "== register the coordinator + add the workers ==" >&2
psql_c "$coord" "SELECT citus_set_coordinator_host('127.0.0.1', ${coord});"
i=0
for p in ${PGPORTS}; do
  if [ "$i" -ne 0 ]; then
    psql_c "$coord" "SELECT citus_add_node('127.0.0.1', ${p});"
  fi
  i=$((i + 1))
done

echo "== distribute a table + round-trip data via the coordinator ==" >&2
psql_c "$coord" "CREATE TABLE items (id bigint, val text);"
psql_c "$coord" "SELECT create_distributed_table('items', 'id');"
psql_c "$coord" "INSERT INTO items SELECT g, 'v' || g FROM generate_series(1, 100) g;"

echo "== assert membership + distributed data ==" >&2
nodes="$(psql_c "$coord" "SELECT count(*) FROM pg_dist_node WHERE isactive;")"
rows="$(psql_c "$coord" "SELECT count(*) FROM items;")"
shards="$(psql_c "$coord" "SELECT count(*) FROM citus_shards WHERE table_name = 'items'::regclass;")"
echo "   active nodes=${nodes} (want ${NUM_CLUSTERS}), rows=${rows} (want 100), shards=${shards}" >&2

[ "$nodes" = "${NUM_CLUSTERS}" ] || { echo "FAIL: expected ${NUM_CLUSTERS} active nodes, got ${nodes}" >&2; exit 1; }
[ "$rows" = "100" ] || { echo "FAIL: expected 100 rows, got ${rows}" >&2; exit 1; }
[ "${shards:-0}" -ge 1 ] || { echo "FAIL: items has no shards (not distributed)" >&2; exit 1; }

echo "OK: citus integration passed (${nodes} nodes, ${rows} distributed rows, ${shards} shards)" >&2
