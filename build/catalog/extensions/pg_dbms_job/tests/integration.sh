#!/bin/bash
# shellcheck disable=SC2154,SC2250,SC2292,SC2310
# pg_dbms_job hermetic integration assertion.
#
# Ported from the upstream asynchronous-job TAP test t/02_async.t (and its
# companion test/sql/async.sql), which submits a job with no next_date/interval
# so the leader background worker executes it immediately, then checks that the
# queue drains and one row lands in the run-history table. The upstream test
# leans on a pre-created regress_dbms_job database, a dedicated job role, and
# `ps auwx` to eyeball the worker; here we assert the same behaviour purely
# through SQL so it stays hermetic and single-node.
#
# Invoked by regress_runner.sh --kind integration with NUM_CLUSTERS=1 live on
# 127.0.0.1 (PGPORT_0), pg_dbms_job already in shared_preload_libraries. The
# leader worker connects to its default database (pg_dbms_job.database defaults
# to "postgres") as the bootstrap superuser (pg_dbms_job.username defaults to
# NULL), which is exactly the node/role this script drives, so no extra GUCs are
# needed. The worker auto-restarts every 5s (bgw_restart_time) until the
# extension objects exist, so it starts servicing the queue within a few seconds
# of CREATE EXTENSION. The exit code is the verdict; there is no golden output.
set -euo pipefail

port="${PGPORT_0}"

psql_c() {  # psql_c <sql> -> bare scalar (unaligned, tuples-only)
  psql -h 127.0.0.1 -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -At -c "$1"
}

echo "== CREATE EXTENSION pg_dbms_job ==" >&2
psql_c "CREATE EXTENSION pg_dbms_job;"

echo "== poll (<=30s) for the leader background worker to be running ==" >&2
# The worker starts at postmaster boot, before this script runs, so its first
# ticks error out ("dbms_job.all_scheduled_jobs does not exist") and it exits;
# bgw_restart_time=5 restarts it every 5s until CREATE EXTENSION above makes the
# objects exist, after which it stays up. bgw_type is PGDJ_APPNAME
# ("pg_dbms_job") for the leader (":worker" for the transient per-job children).
up=0 i=0
while [ "$i" -lt 30 ]; do
  worker="$(psql_c "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'pg_dbms_job';")"
  if [ "${worker:-0}" -ge 1 ]; then up=1; break; fi
  i=$((i + 1)); sleep 1
done
[ "$up" = 1 ] || { echo "FAIL: pg_dbms_job leader background worker never came up" >&2; exit 1; }

echo "== submit an async job that creates + populates a marker table ==" >&2
# what is executed as the body of a DO $pg_dbms_job$ ... $ PL/pgSQL block by the
# worker, so the statements below run in that context. Submitting with the
# default next_date (now) and no interval makes it an immediate async job, per
# test/sql/async.sql.
psql_c "SELECT dbms_job.submit(
  \$job\$
    CREATE TABLE public.dbms_job_marker(id int);
    INSERT INTO public.dbms_job_marker VALUES (42);
  \$job\$
);"

echo "== poll (<=60s) for the worker to drain the queue + run the job ==" >&2
# Mirrors t/02_async.t's post-conditions: the job leaves all_async_jobs and one
# row appears in the run-history table. We also confirm the marker table exists,
# proving the worker executed the job's arbitrary SQL end to end.
ran=0 i=0
while [ "$i" -lt 60 ]; do
  queued="$(psql_c "SELECT count(*) FROM dbms_job.all_async_jobs;" 2>/dev/null || echo 1)"
  marker="$(psql_c "SELECT count(*) FROM pg_catalog.pg_class WHERE relname = 'dbms_job_marker';" 2>/dev/null || echo 0)"
  if [ "${queued:-1}" = "0" ] && [ "${marker:-0}" -ge 1 ]; then ran=1; break; fi
  i=$((i + 1)); sleep 1
done
[ "$ran" = 1 ] || {
  echo "FAIL: worker did not run the async job within 60s (queued=${queued}, marker=${marker})" >&2
  exit 1
}

echo "== assert the job effect + the run-history row ==" >&2
val="$(psql_c "SELECT id FROM public.dbms_job_marker LIMIT 1;")"
hist="$(psql_c "SELECT count(*) FROM dbms_job.all_scheduler_job_run_details;")"
[ "$val" = "42" ] || { echo "FAIL: marker table has wrong value (${val})" >&2; exit 1; }
[ "${hist:-0}" -ge 1 ] || { echo "FAIL: no row in the run-history table (got ${hist})" >&2; exit 1; }

echo "OK: pg_dbms_job async job executed by the worker (marker=${val}, history rows=${hist})" >&2
