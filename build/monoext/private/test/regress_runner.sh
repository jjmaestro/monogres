#!/bin/bash
# shellcheck disable=SC2154,SC2250,SC2292,SC2249,SC2312
# Hermetic pg_regress / pg_isolation_regress harness.
#
# Runs an upstream PostgreSQL regression suite against an INSTALLED artifact tree
# (relocated into the sandbox, private datadir, ZERO build tree, no host PG, no
# network), with the runtime library closure sourced from the sysroots, the
# test-execution analog of the hermetic build's sysroot_setup.sh. Each suite is
# one `bazel test` target; pg_regress runs its own throwaway `--temp-instance`.
#
# This is the shared harness the test-target codegen drives; the generator emits
# only the IDENTITY + SHAPE of a suite and the runfiles, and this script
# reconstructs the real invocation from the installed tree. Contract (see
# report_build/streams/F_codegen/CALL_CONVENTION.md):
#
#   $1  closure_setup.sh        (the runtime-closure populator)
#   $2  sysroot_lib.sh          (shared extract/multiarch/symlink helpers, passed
#                                through to closure_setup)
#   $3  bsdtar                  (static; runs before any libc is present)
#   $4  runtime sysroot tar     (@pg//<v>/deps/runtime:sysroot_tar; carries glibc)
#   then a free mix, any order, of:
#     - $(rlocationpath ...) tree files: the install tree (@pg//<v>/<opt>:tar)
#       and the source tree (@pg//<v>/src:dir). Classified by content:
#       `bin/initdb` => install-tree root (PGROOT); a dir containing
#       `src/test/regress/parallel_schedule` => source-tree root.
#     - --flag value selectors:
#         --kind regress|isolation|tap|setup   (default: regress)
#         --suite <name>                        (outputdir subdir + log banner)
#         --schedule <basename>                 (schedule file under the srcdir)
#         --tests <name>                        (inline test list, repeatable; alt
#                                                to schedule)
#         --dlpath-from <rloc>                  (rloc of a regress.so dir => --dlpath)
#         --max-conc <N>                        (--max-concurrent-tests)
#         --version|--flavor|--option-set <v>   (informational)
#
# Env: REGRESS_INITDB_TEMPLATE=1 (PG17+) => use the installed initdb template;
#      0/unset (PG16) => pg_regress runs initdb itself. TEST_UNDECLARED_OUTPUTS_DIR
#      (Bazel) collects regression.diffs + logs.
set -euo pipefail

# --- begin runfiles.bash initialization v3 ---
set +e
f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
  source "$0.runfiles/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  source "$0.exe.runfiles/$f" 2>/dev/null ||
  { echo >&2 "ERROR: cannot find $f"; exit 1; }
set -e
# --- end runfiles.bash initialization v3 ---

[ "$#" -ge 4 ] || { echo "ERROR: usage: $0 <closure_setup> <sysroot_lib> <bsdtar> <runtime_tar> <trees...> [flags]" >&2; exit 2; }
closure_setup="$(rlocation "$1")"
sysroot_lib="$(rlocation "$2")"
bsdtar="$(rlocation "$3")"
runtime_tar="$(rlocation "$4")"
shift 4

kind="regress"
suite=""
schedule=""
tests=""
dlpath=""
max_conc=""
dbname=""
test_tar=""
tap_env_args=""
srcdir_subtree=""
tap_file=""
skip_reason=""
temp_config=""
temp_config_srcrel=""
regress_opts=""
version=""
flavor=""
optset=""
initdb=""
srcroot=""
run_cwd=""
exclude_tests=""
golden_cosmetic=""
initdb_mode=""
initdb_compat=""
inputdir_rel=""
mode="regress"
overlay_tars=""
ext_srcdir=""
ext_inputdir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind) kind="$2"; shift 2 ;;
    --suite) suite="$2"; shift 2 ;;
    --schedule) schedule="$2"; shift 2 ;;
    # One test name per flag, accumulated in the order given (pg_regress runs a
    # `--tests` list in order, and a suite's first test is often its setup).
    # Repeatable rather than one space-joined value because a rule's `args` are
    # Bourne-tokenized before they reach here: a single "a b c" arrives as three
    # argv entries, so the flag would take `a` and the rest would fall through
    # the loop and be dropped.
    --tests) tests="$tests $2"; shift 2 ;;
    # A test name to DROP from a --schedule-driven suite (the codegen cannot drop
    # a single test from a schedule, so the harness filters the schedule at run
    # time). For a known fork-divergent spec in an otherwise green schedule, e.g.
    # openHalo isolation `timeouts`. Repeatable, for the same reason as --tests.
    --exclude-tests) exclude_tests="$exclude_tests $2"; shift 2 ;;
    # accept a pg_regress failure whose diff is PURELY cosmetic psql table
    # rendering (trailing whitespace + separator dash/plus width, no data rows),
    # for a known fork golden diff, e.g. openHalo postgres_fdw EXPLAIN width.
    --golden-cosmetic) golden_cosmetic="$2"; shift 2 ;;
    --max-conc) max_conc="$2"; shift 2 ;;
    # the suite's exact pg_regress database (overrides the per-kind default
    # below). Every meson regress/isolation cmd names one; make/oracle fall back.
    --dbname) dbname="$2"; shift 2 ;;
    --temp-config-from)
      tc="$(rlocation "$2" 2>/dev/null || true)"
      if [ -n "$tc" ]; then temp_config="$tc"; fi
      shift 2 ;;
    # repo-root-relative path of an upstream --temp-config .conf that rides the
    # PG :src tree (modules test_slru / snapshot_too_old / worker_spi); resolved
    # to an absolute path below, once the source root is known. A checked-in
    # --temp-config-from (above) wins.
    --temp-config-srcrel) temp_config_srcrel="$2"; shift 2 ;;
    # verbatim pass-through to pg_regress (repeatable), e.g. --load-extension=<ext>.
    --regress-opt) regress_opts="$regress_opts $2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --flavor) flavor="$2"; shift 2 ;;
    --option-set) optset="$2"; shift 2 ;;
    --dlpath-from)
      d="$(rlocation "$2" 2>/dev/null || true)"
      [ -n "$d" ] && dlpath="$(dirname "$d")"
      shift 2 ;;
    # rloc of the `test` deps sysroot tar (@pg//<v>/deps/test:sysroot_tar),
    # layered onto the runtime closure for the TAP lane: supplies IPC::Run, the
    # PostgreSQL::Test driver dep deliberately kept out of the production runtime.
    --test-sysroot-from)
      t="$(rlocation "$2" 2>/dev/null || true)"
      [ -n "$t" ] && test_tar="$t"
      shift 2 ;;
    # K=V build-config env gate for the TAP lane (with_ldap, enable_injection_points,
    # ...), mirrored from the introspect TAP entry env; applied in the TAP branch.
    --tap-env) tap_env_args="$tap_env_args $2"; shift 2 ;;
    # The suite's source subtree (src/test/recovery, src/bin/pg_dump, ...) from
    # the introspect; the harness resolves srcdir against it directly (meson).
    --srcdir-subtree) srcdir_subtree="$2"; shift 2 ;;
    # A single TAP .pl basename to run (per-.pl target, e.g. 001_stream_rep);
    # empty falls back to running every t/*.pl in the suite (make path).
    --tap-file) tap_file="$2"; shift 2 ;;
    # host-capability TAP test (e.g. a controlling-terminal pty); the harness
    # TAP-skips it (see below) so the hermetic suite stays green.
    --skip-reason) skip_reason="$2"; shift 2 ;;
    # IvorySQL oracle-mode template: see the oracle template block below.
    --initdb-mode) initdb_mode="$2"; shift 2 ;;
    --initdb-compat) initdb_compat="$2"; shift 2 ;;
    # explicit <inputdir> relative to the source root (main oracle suite).
    --inputdir-rel) inputdir_rel="$2"; shift 2 ;;
    # interactive psql dev mode (bazel run, un-sandboxed).
    --mode) mode="$2"; shift 2 ;;
    # rloc of ONE extension artifact tar (repeatable), overlaid onto a writable
    # copy of PGROOT so a separately-built PGXS extension's .so/.control/.sql
    # land where PG (pre-PG18) resolves them. External lane only.
    --overlay-tar)
      t="$(rlocation "$2" 2>/dev/null || true)"
      if [ -n "$t" ]; then overlay_tars="$overlay_tars $t"; fi
      shift 2 ;;
    # rloc of the external extension's source-tree root (its sql/+expected/),
    # joined with --ext-inputdir. External source has no
    # src/test/regress/parallel_schedule for the default classifier.
    --ext-srcdir)
      d="$(rlocation "$2" 2>/dev/null || true)"
      [ -n "$d" ] && ext_srcdir="$d"
      shift 2 ;;
    --ext-inputdir) ext_inputdir="$2"; shift 2 ;;
    --*) echo "WARN: ignoring unknown flag $1" >&2; shift 2 ;;
    *)
      r="$(rlocation "$1" 2>/dev/null || true)"
      if [ -n "$r" ]; then
        # initdb marks the install-tree root, reached via two runfiles shapes:
        # meson stages the tree as individual files (a positional IS the
        # `.../bin/initdb` leaf), while make stages it as one tree artifact (a
        # positional is the tree-ROOT dir that CONTAINS `bin/initdb`).
        case "$r" in
          */bin/initdb) initdb="$r" ;;
          *) [ -z "$initdb" ] && [ -f "$r/bin/initdb" ] && initdb="$r/bin/initdb" ;;
        esac
        if [ -z "$srcroot" ] && [ -f "$r/src/test/regress/parallel_schedule" ]; then
          srcroot="$r"
        fi
      fi
      shift ;;
  esac
done

# meson's `postgresql:setup` (exitcode) targets are build-tree setup steps with
# no meaning against an installed tree; exit 0 with a SKIP banner so the suite
# still enumerates. (TAP runs for real, below, after the closure is assembled.)
case "$kind" in
  setup)
    echo "SKIP: kind=$kind (suite=$suite) not run in the hermetic lane" >&2
    exit 0 ;;
esac

# A host-capability TAP test the codegen marks with --skip-reason: the hermetic
# sandbox cannot provide the capability (e.g. a controlling-terminal pty) and the
# suite cannot skip on its own (IO::Pty rides the closure via libipc-run-perl),
# so emit a TAP skip-all and exit 0, the hermetic analog of the suite's own
# `skip_all`. It still runs for real on a host with the capability (drop the arg).
if [ -n "$skip_reason" ]; then
  echo "1..0 # SKIP $skip_reason" >&2
  exit 0
fi

# -running suites expect a pre-existing server (--use-existing); the locked
# design uses a per-suite --temp-instance, so skip them (the override layer can
# repoint them later).
case "$suite" in
  *-running)
    echo "SKIP: suite=$suite (use-existing-server) not run in the --temp-instance lane" >&2
    exit 0 ;;
esac

[ -n "$initdb" ] || { echo "ERROR: bin/initdb not found among install-tree runfiles" >&2; exit 1; }
# The external-extension lane reads its source from --ext-srcdir, not the PG
# src tree, so only require a PG srcroot when no --ext-srcdir was given.
if [ -z "$ext_srcdir" ]; then
  [ -n "$srcroot" ] || { echo "ERROR: source tree (src/test/regress/parallel_schedule) not found" >&2; exit 1; }
fi

# An introspect-derived --temp-config names a .conf in the suite's OWN source
# subtree (it rides the PG :src tree); resolve it against the located source root
# now that srcroot is known, unless a checked-in --temp-config-from already set
# one. Modules like test_slru / snapshot_too_old depend on this overlay
# (shared_preload_libraries); without it CREATE EXTENSION errors "must be loaded
# with shared_preload_libraries".
if [ -z "$temp_config" ] && [ -n "$temp_config_srcrel" ] && [ -n "$srcroot" ]; then
  temp_config="$srcroot/$temp_config_srcrel"
  [ -f "$temp_config" ] || { echo "ERROR: --temp-config-srcrel '$temp_config_srcrel' not found under source root" >&2; exit 1; }
fi

PGROOT="$(dirname "$(dirname "$initdb")")"

# --- interactive psql dev mode (bazel run, un-sandboxed, inside the container) ---
# Spins the temp instance the test lane would, then drops into psql instead of
# pg_regress. The container has the ELF loader + glibc, so the runtime closure
# is reached via LD_LIBRARY_PATH (no chroot /lib symlink; this is not sandboxed).
if [ "$mode" = "psql" ]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/pgpsql.XXXXXX")"
  # Stop the server cleanly (-w waits for the postmaster to exit) BEFORE removing
  # the datadir; an unwaited `-m immediate` lets the WAL writer outlive pg_ctl and
  # PANIC on the vanishing `pg_wal/` as `rm -rf` races it. Full bin path: psql mode
  # does not put `bin/` on PATH.
  trap '"$PGROOT/bin/pg_ctl" -D "$WORK/data" -m fast -w stop >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT INT TERM
  CLOSURE="$WORK/closure"
  multiarch="$(bash "$closure_setup" "$sysroot_lib" "$bsdtar" "$CLOSURE" "$runtime_tar" --mode run)"
  export LD_LIBRARY_PATH="$CLOSURE/lib/$multiarch:$CLOSURE/usr/lib/$multiarch:$PGROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  # perl/python stdlib dirs are release-versioned; resolve the versioned dir
  # names from the closure (bookworm 5.36/3.11, trixie 5.40/3.13) instead of
  # hardcoding one release. Debian keeps core perl modules under the
  # two-component dir (perl/5.40, not 5.40.1), so pick that. Tcl is 8.6 across
  # releases (deps-pinned).
  perl_ver=""
  for d in "$CLOSURE/usr/share/perl"/[0-9]*; do
    case "${d##*/}" in
      *.*.*) : ;;
      *.*) [ -d "$d" ] && perl_ver="${d##*/}" ;;
    esac
  done
  py_dir=""
  for d in "$CLOSURE/usr/lib"/python3.*; do [ -d "$d" ] && py_dir="${d##*/}"; done
  export PYTHONHOME="$CLOSURE/usr"
  export PYTHONPATH="$CLOSURE/usr/lib/$py_dir:$CLOSURE/usr/lib/$py_dir/lib-dynload"
  export PYTHONNOUSERSITE=1
  export PERL5LIB="$CLOSURE/usr/lib/$multiarch/perl-base:$CLOSURE/usr/lib/$multiarch/perl/$perl_ver:$CLOSURE/usr/share/perl/$perl_ver:$CLOSURE/usr/share/perl5"
  export TCL_LIBRARY="$CLOSURE/usr/share/tcltk/tcl8.6"
  export TCL8_6_TM_PATH="$CLOSURE/usr/share/tcltk/tcl8.6/tcl8"
  export LC_ALL=C LANG=C
  SOCK="$(mktemp -d /tmp/pgr.XXXXXX)"
  "$PGROOT/bin/initdb" -D "$WORK/data" --no-locale -U postgres >&2
  "$PGROOT/bin/pg_ctl" -D "$WORK/data" -o "-k '$SOCK' -p 5432 -c listen_addresses=''" -w start >&2
  echo "== psql dev instance: v=${version:-?}/${flavor:-?}/${optset:-?} datadir=$WORK/data ==" >&2
  PGHOST="$SOCK" PGPORT=5432 "$PGROOT/bin/psql" -U postgres -d postgres "$@"
  exit $?
fi

# Extension-test lane: overlay separately-built PGXS extension artifact tars
# onto a WRITABLE copy of the PG install tree, then run against the merge. The
# runfiles PGROOT is read-only and PG (pre-PG18) only searches pkglibdir +
# SHAREDIR/extension under its own install root. pgxs_build tars its install dir
# as `.`, so each tar roots at `./<flavor>/<base_v>/...` (the relocation
# prefix); strip those three leading components so `lib/` + `share/extension/`
# land at the PGROOT root. cp -al hardlinks the (large) PG tree near-free.
if [ -n "$overlay_tars" ]; then
  MERGED="$TEST_TMPDIR/pgroot-${suite:-$kind}"
  rm -rf "$MERGED" 2>/dev/null || true
  mkdir -p "$MERGED"
  cp -al "$PGROOT/." "$MERGED/" 2>/dev/null || cp -a "$PGROOT/." "$MERGED/"
  chmod -R u+w "$MERGED" 2>/dev/null || true
  # shellcheck disable=SC2086  # intentional word-split: space-separated rlocs
  for t in $overlay_tars; do
    "$bsdtar" -xf "$t" -C "$MERGED" --strip-components=3 2>/dev/null || {
      echo "ERROR: failed to overlay extension tar: $t" >&2; exit 1; }
  done
  echo "   overlaid $(printf '%s' "$overlay_tars" | wc -w) extension tar(s) onto a writable PGROOT" >&2
  PGROOT="$MERGED"
fi

# Runner by kind. The pgxs test infra installs under a flavor-dependent dir
# (`lib/pgxs` for postgres, `lib/postgresql/pgxs` for the openHalo/babelfish
# forks), so locate the runner by name under PGROOT/lib rather than hardcoding
# the pgxs subpath.
case "$kind" in
  isolation)
    runner="$(find "$PGROOT/lib" -type f -name pg_isolation_regress 2>/dev/null | head -1)"
    dbname="${dbname:-isolation_regression}"
    ;;
  *)
    runner="$(find "$PGROOT/lib" -type f -name pg_regress 2>/dev/null | head -1)"
    dbname="${dbname:-regression}"
    ;;
esac
if [ ! -x "$runner" ]; then
  echo "ERROR: runner not executable: $runner" >&2
  exit 1
fi

# Input/source dir by suite. Core suites (regress / isolation) live under
# src/test/<kind>; contrib + test-module suites bring their own sql|specs +
# expected and run with CWD there (their `\copy`/spec paths are relative). This
# holds for BOTH kinds: a contrib suite classified isolation (e.g. it ships a
# .spec) still lives at contrib/<suite>, not the core src/test/isolation.
if [ -z "$suite" ] || [ "$suite" = "regress" ] || [ "$suite" = "isolation" ]; then
  if [ "$kind" = "isolation" ]; then
    srcdir="$srcroot/src/test/isolation"
  else
    srcdir="$srcroot/src/test/regress"
  fi
else
  # contrib, test-module, PL-language, and the per-component TAP suites
  # (src/bin/<tool>, src/test/recovery, ...) bring their own sql|specs|t +
  # expected and run with CWD there. pg_regress reads its inputs from
  # <inputdir>/sql (regress) or <inputdir>/specs (isolation); TAP reads t/*.pl.
  need="sql"
  [ "$kind" = "isolation" ] && need="specs"
  [ "$kind" = "tap" ] && need="t"
  if [ -n "$srcdir_subtree" ]; then
    # meson: the introspect names the exact source subtree (src/test/modules/brin,
    # src/test/recovery, src/bin/pg_dump, contrib/amcheck, ...), so resolve the
    # srcdir directly instead of guessing from the slug.
    srcdir="$srcroot/$srcdir_subtree"
    [ -d "$srcdir/$need" ] || {
      echo "ERROR: no '$need' dir at subtree '$srcdir_subtree' (suite '$suite')" >&2
      exit 1
    }
  else
    # make path: no introspect subtree, so guess from the slug. PL languages
    # live under src/pl/ with a couple non-uniform dirs (pltcl -> src/pl/tcl,
    # plpgsql -> src/pl/plpgsql/src); pick the first candidate that actually
    # holds the inputs, not merely an existing directory.
    cands="contrib/$suite src/test/modules/$suite src/pl/$suite"
    case "$suite" in
      pltcl) cands="$cands src/pl/tcl" ;;
      plpgsql) cands="$cands src/pl/plpgsql/src" ;;
    esac
    srcdir=""
    for cand in $cands; do
      if [ -d "$srcroot/$cand/$need" ]; then
        srcdir="$srcroot/$cand"
        break
      fi
    done
    [ -n "$srcdir" ] || {
      echo "ERROR: no '$need' dir for suite '$suite' (tried: $cands)" >&2
      exit 1
    }
  fi
  run_cwd="$srcdir"
fi

# Explicit-inputdir overrides (take precedence over the name-derived srcdir,
# so the core path stays byte-identical when neither is set):
#  - --inputdir-rel: a suite whose tree the name-resolver does not know (the
#    main oracle suite at src/oracle_test/regress).
#  - --ext-srcdir: an external extension's OWN source (its REGRESS_OPTS
#    --inputdir), joined with --ext-inputdir (e.g. pgvector's `test`).
if [ -n "$inputdir_rel" ]; then
  srcdir="$srcroot/$inputdir_rel"
  [ -d "$srcdir" ] || { echo "ERROR: --inputdir-rel '$inputdir_rel' not found under source root" >&2; exit 1; }
  [ "$kind" = "isolation" ] && run_cwd="$srcdir"
elif [ -n "$ext_srcdir" ]; then
  srcdir="$ext_srcdir${ext_inputdir:+/$ext_inputdir}"
  run_cwd="$srcdir"
fi

# regress.so is captured into the install tree's pkglibdir by pg_build's
# postfix_script, so default --dlpath there for the regress kind (test_setup.sql
# does CREATE FUNCTION ... AS '@libdir@/regress.so'). An explicit --dlpath-from
# (a separate :test-libs label) overrides this. Contrib/isolation need no dlpath.
if [ "$kind" = "regress" ] && [ -z "$dlpath" ] && [ -e "$PGROOT/lib/postgresql/regress.so" ]; then
  dlpath="$PGROOT/lib/postgresql"
fi

# ---- runtime closure (test-execution analog of sysroot_setup.sh) ----
export LC_ALL=C LANG=C
CLOSURE="${TEST_TMPDIR:?TEST_TMPDIR unset}/closure"
# The TAP lane passes a `test` deps sysroot tar (IPC::Run); closure_setup.sh is
# additive and multi-tar, so layer it onto the runtime closure when present.
# shellcheck disable=SC2086  # intentional: ${test_tar:+...} expands to 0 or 1 arg
multiarch="$(bash "$closure_setup" "$sysroot_lib" "$bsdtar" "$CLOSURE" "$runtime_tar" ${test_tar:+"$test_tar"})"

# tzdata: PG is built --with-system-tzdata=/usr/share/zoneinfo, so pg_regress
# reads whatever timezone database lives there at run time. The runtime closure
# carries the pinned apt-snapshot tzdata, which drifts ahead of each PG minor's
# frozen expected-output as IANA refines historical zones (e.g. Asia/Manila's
# pre-1900 LMT), shifting the timestamptz/horology goldens. Compile THIS
# version's OWN bundled tzdata -- the release its goldens were generated against
# -- with the closure's zic, exactly as PG's `make install` does
# (zic -d <dir> tzdata.zi, no extra options), into a private zoneinfo so the
# tz-sensitive suites match their goldens regardless of the snapshot. Fall back
# to the snapshot tzdata when the bundled source or zic is absent.
zoneinfo="$CLOSURE/usr/share/zoneinfo"
if [ -f "$srcroot/src/timezone/data/tzdata.zi" ] && [ -x "$CLOSURE/usr/sbin/zic" ]; then
  if "$CLOSURE/usr/sbin/zic" -d "$CLOSURE/usr/share/zoneinfo.pg" \
      "$srcroot/src/timezone/data/tzdata.zi" 2>/dev/null; then
    zoneinfo="$CLOSURE/usr/share/zoneinfo.pg"
  fi
fi
# Bridge the configured absolute system_tzdata path to the chosen zoneinfo, and
# satisfy Debian tzdata's relative zoneinfo/localtime -> ../../../etc/localtime
# (resolves to $CLOSURE/etc/localtime through the bridged dir) so
# pg_timezone_names() works.
if [ -d "$zoneinfo" ] && [ ! -e /usr/share/zoneinfo ]; then
  mkdir -p /usr/share 2>/dev/null || true
  ln -s "$zoneinfo" /usr/share/zoneinfo 2>/dev/null || true
fi
mkdir -p "$CLOSURE/etc" 2>/dev/null || true
[ -e "$CLOSURE/etc/localtime" ] || ln -s "$zoneinfo/UTC" "$CLOSURE/etc/localtime" 2>/dev/null || true
if [ ! -e /etc/localtime ]; then
  mkdir -p /etc 2>/dev/null || true
  ln -s "$zoneinfo/UTC" /etc/localtime 2>/dev/null || true
fi

# locale data: glibc's `locale -a` (which initdb runs to seed pg_collation via
# pg_import_system_collations) scans the compiled-in absolute /usr/lib/locale,
# not $CLOSURE or LOCPATH. libc-bin ships C.utf8 there, so bridge the closure's
# locale dir to the absolute path; without it initdb sees only the built-in
# C/POSIX and warns "no usable system locales were found".
if [ -d "$CLOSURE/usr/lib/locale" ] && [ ! -e /usr/lib/locale ]; then
  mkdir -p /usr/lib 2>/dev/null || true
  ln -s "$CLOSURE/usr/lib/locale" /usr/lib/locale 2>/dev/null || true
fi

# ---- loopback name resolution (PG<=14 statistics collector self-test) ----
# PG<=14 (the openHalo base) runs its statistics collector over a UDP socket it
# self-tests against `localhost`. In the hermetic network namespace `localhost`
# resolves to `::1` first and the IPv6 loopback datagram path is non-functional,
# so the collector disables itself, forces `track_counts=off`, and the core
# `stats` regression test both stalls (its bounded poll loop never early-exits)
# and golden-diffs. Pin `localhost` to the IPv4 loopback (which is up) with a
# files-only resolution so the self-test succeeds. No-op for PG>=15 (shared-
# memory cumulative stats; no collector socket). The sandbox mounts only
# /etc/passwd, so /etc/hosts + /etc/nsswitch.conf are absent and writable here;
# nsswitch keeps passwd/group on `files` (the mounted /etc/passwd) so getpwuid
# still resolves.
if [ ! -e /etc/hosts ]; then
  printf '127.0.0.1 localhost\n' > /etc/hosts 2>/dev/null || true
fi
if [ ! -e /etc/nsswitch.conf ]; then
  printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files\n' > /etc/nsswitch.conf 2>/dev/null || true
fi

# PG was built with rpath=false: bridge its own client libs (libpq.so.5, ...)
# from PGROOT/lib into the chroot's standard multiarch path, as the OCI runtime
# layer would. Backend modules under PGROOT/lib/postgresql load via pkglibdir.
pg_libdst="/usr/lib/$multiarch"
mkdir -p "$pg_libdst" 2>/dev/null || true
for src in "$PGROOT"/lib/*.so*; do
  [ -e "$src" ] || continue
  dst="$pg_libdst/$(basename "$src")"
  [ -e "$dst" ] && continue
  ln -s "$src" "$dst" 2>/dev/null || true
done

# ---- embedded-PL interpreter library roots (plpython3u / plperl / pltcl) ----
# The PL .so's embed an interpreter that resolves its stdlib from compiled-in
# absolute Debian paths (/usr/lib/python3.N, /usr/share/perl/5.NN,
# /usr/share/tcltk/tcl8.6); those trees live under $CLOSURE in the relocated
# closure (Python/Tcl stdlibs ride the runtime closure transitively; Perl needs
# the perl-base + perl-modules-<ver> runtime deps). Point each interpreter's
# search root there; inherited by the postmaster pg_regress starts, so a dlopen'd
# PL module finds its modules instead of crashing the backend.
#
# The perl and python stdlib dirs are release-versioned, and the exact versions
# ride the active Debian release's runtime closure (bookworm perl 5.36 / python
# 3.11, trixie perl 5.40 / python 3.13), so resolve the versioned dir names from
# the closure rather than baking one release's numbers in. Debian keeps its core
# perl modules under the two-component version dir (perl/5.40, beside the
# three-component 5.40.1 site dir), so select that one. Tcl is pinned to 8.6 by
# the deps across releases, so its paths stay literal.
perl_ver=""
for d in "$CLOSURE/usr/share/perl"/[0-9]*; do
  case "${d##*/}" in
    *.*.*) : ;;
    *.*) [ -d "$d" ] && perl_ver="${d##*/}" ;;
  esac
done
py_dir=""
for d in "$CLOSURE/usr/lib"/python3.*; do [ -d "$d" ] && py_dir="${d##*/}"; done
export PYTHONHOME="$CLOSURE/usr"
export PYTHONPATH="$CLOSURE/usr/lib/$py_dir:$CLOSURE/usr/lib/$py_dir/lib-dynload"
export PYTHONNOUSERSITE=1
export PERL5LIB="$CLOSURE/usr/lib/$multiarch/perl-base:$CLOSURE/usr/lib/$multiarch/perl/$perl_ver:$CLOSURE/usr/share/perl/$perl_ver:$CLOSURE/usr/share/perl5"
export TCL_LIBRARY="$CLOSURE/usr/share/tcltk/tcl8.6"
# pltcl's clock.tcl does `package require msgcat`, a Tcl `.tm` module under
# $TCL_LIBRARY/tcl8/ (Debian layout). Tcl seeds its module search path from
# compiled-in roots that point at absent host paths, so point the
# version-keyed TM-path env var at the closure's module dir; without it
# `package require msgcat 1.6` fails inside any clock/locale-using PL/Tcl proc.
export TCL8_6_TM_PATH="$CLOSURE/usr/share/tcltk/tcl8.6/tcl8"

# ---- TAP lane (perl PostgreSQL::Test), mirroring src/tools/testwrap ----
# meson drives every test through src/tools/testwrap (a thin python wrapper); we
# run the .pl directly, exactly as the regress lane bypasses testwrap to invoke
# pg_regress with the introspect args. We replicate ONLY testwrap's
# behaviour-affecting setup ("bucket A": chdir to srcdir, TESTDATADIR/TESTLOGDIR,
# PG_TEST_EXTRA). Its meson result-tracking ("bucket B": the testrun/ dir, the
# test.start/success/fail markers, the `# TODO` stdout munge for meson bug
# #13183, and the --skip short-circuit) is meson-only and intentionally dropped;
# running the .pl directly is also why the production introspect's
# `--skip "TAP tests not enabled"` never reaches us.
if [ "$kind" = "tap" ]; then
    tap_out="${TEST_UNDECLARED_OUTPUTS_DIR:-$TEST_TMPDIR/out}/${suite:-tap}"
    mkdir -p "$tap_out"
    # testwrap exports TESTDATADIR/TESTLOGDIR; PostgreSQL::Test::Utils reads them
    # to place each node's datadir + logs. Point them into the undeclared outputs
    # so a failing run's clusters/logs are collected. (PostgreSQL::Test puts the
    # unix socket under its own tempdir_short, NOT here, so the long bazel path is
    # fine for data/logs.)
    export TESTDATADIR="$tap_out/data"
    export TESTLOGDIR="$tap_out/log"
    # PG <= 15's PostgreSQL::Test::Utils predates TESTDATADIR/TESTLOGDIR: it reads
    # TESTDIR and roots tmp_check (each node's basedir, holding data + logs +
    # archives) at "$TESTDIR/tmp_check", defaulting to a RELATIVE "tmp_check" when
    # unset. A relative basedir is fatal for file-shipping suites: enable_archiving
    # bakes the archive dir into archive_command/restore_command as
    # `cp "%p" "<basedir>/archives/%f"`, and the server runs that with CWD=datadir,
    # so a relative path ships the WAL to the wrong place and the standby never
    # advances (poll_query_until times out). Point TESTDIR at the (absolute)
    # collected output dir so the basedir is absolute; PG16+ ignore TESTDIR (they
    # read TESTDATADIR/TESTLOGDIR set above).
    export TESTDIR="$tap_out"
    # tempdir_short (the socket host) honours TMPDIR, and Bazel's TEST_TMPDIR is
    # too long for sun_path (107); point it at a short /tmp dir, as the regress
    # lane does for its own socket.
    TMPDIR="$(mktemp -d /tmp/tap.XXXXXX 2>/dev/null || mktemp -d)"
    export TMPDIR
    # PostgreSQL::Test::* live in the source tree (src/test/perl); a suite's own
    # helpers sit beside its tests. meson passes both as `perl -I`; we fold them
    # into PERL5LIB ahead of the closure libs (which carry IPC::Run from the test
    # sysroot + perl-base/Test::More).
    export PERL5LIB="$srcroot/src/test/perl:$srcdir${PERL5LIB:+:$PERL5LIB}"
    # PostgreSQL::Test::Cluster locates the server binaries via PATH and PG_REGRESS.
    # test_bin/ holds the install:false test helper programs a few suites run by
    # bare name (src/test/modules: test_escape, libpq_pipeline, test_json_parser_*;
    # src/interfaces/libpq/test: libpq_uri_regress, libpq_testclient;
    # src/tools/pg_bsd_indent: pg_bsd_indent); the test variant stages them there
    # (see pg_build.bzl _TEST_MODULES_CAPTURE). $CLOSURE/usr/bin trails the PATH so
    # the glibc utilities initdb shells out to (locale, for ICU/libc locale
    # enumeration) resolve without shadowing the busybox tools ahead of them.
    export PATH="$PGROOT/bin:$PGROOT/test_bin:$PATH:$CLOSURE/usr/bin"
    export PG_REGRESS="$runner"
    # Several TAP suites CREATE FUNCTION ... AS '$ENV{REGRESS_SHLIB}' to reach C
    # helpers (e.g. recovery/017_shm's wait_pid) in the regression support lib;
    # meson sets REGRESS_SHLIB to the built regress.so. pg_build captures it into
    # pkglibdir (the regress lane's default --dlpath), so point the env var there.
    [ -e "$PGROOT/lib/postgresql/regress.so" ] && export REGRESS_SHLIB="$PGROOT/lib/postgresql/regress.so"
    # Some suites re-tar a plain backup via $ENV{TAR} (pg_verifybackup's
    # tar-format checks, PG17+); meson sets TAR to the detected tar, and an unset
    # TAR makes the suite die on an undefined command. Prefer the closure's tar,
    # falling back to the harness bsdtar.
    if [ -x "$CLOSURE/usr/bin/tar" ]; then
        export TAR="$CLOSURE/usr/bin/tar"
    else
        export TAR="$bsdtar"
    fi
    # testwrap forwards a configure-time PG_TEST_EXTRA only when unset in the env;
    # the introspect passes it empty, so networked/optional groups (kerberos, ssl,
    # ldap, oauth) stay OFF. We mirror that by leaving PG_TEST_EXTRA unset.
    # Build-config gates the .pl read (with_ldap, with_ssl, enable_injection_points,
    # ...), threaded verbatim from the introspect TAP entry env (per option set, via
    # --tap-env) so a `use warnings FATAL` read of an absent gate cannot abort the
    # script and a suite's own skip logic matches the build. Mirrors the env that
    # src/tools/testwrap inherits from the meson build.
    # shellcheck disable=SC2086,SC2163  # word-split intended; each token is one
    # NAME=VALUE, which `export` assigns directly (SC2163's name-only read is wrong).
    for __kv in $tap_env_args; do export "$__kv"; done
    cd "$srcdir" || { echo "ERROR: tap srcdir not found: $srcdir" >&2; exit 1; }
    echo "== tap suite=${suite:-?} v=${version:-?}/${flavor:-?}/${optset:-?} srcdir=$srcdir ==" >&2
    perl_bin="$CLOSURE/usr/bin/perl"
    [ -x "$perl_bin" ] || perl_bin=perl
    rc=0
    found=0
    # A per-.pl target (meson) runs just the named file; the make path (no
    # --tap-file) runs every t/*.pl. `set --` lets us iterate a quoted list for
    # both shapes (the args were already consumed by the parse loop above).
    if [ -n "$tap_file" ]; then
        set -- "$srcdir/t/$tap_file.pl"
    else
        set -- "$srcdir"/t/*.pl
    fi
    for pl in "$@"; do
        [ -e "$pl" ] || continue
        found=1
        name="$(basename "$pl" .pl)"
        echo "== tap: $name.pl ==" >&2
        # PostgreSQL::Test::Utils redirects the .pl's stdout+stderr into
        # $TESTLOGDIR/regress_log_<name>; on failure surface it (the regress lane
        # likewise dumps regression.diffs) so the cause is visible in the test log.
        if ! "$perl_bin" "$pl"; then
            rc=1
            echo "== regress_log $name (perl failed) ==" >&2
            # PG16 writes regress_log_<name> under TESTLOGDIR ($tap_out/log); PG15
            # under $tap_out/tmp_check/log (TESTDIR). Surface it wherever it landed.
            find "$tap_out" -name "regress_log_$name" -exec cat {} \; >&2 2>/dev/null || true
        fi
    done
    # Bazel collects $tap_out after the sandbox is torn down and rejects symlinks
    # that then dangle. A temp cluster built with a separate WAL or tablespace dir
    # (initdb --waldir, pg_basebackup -T, tablespace tests) leaves a pg_wal/<oid>
    # link pointing at an absolute /execroot sandbox path; that path is gone once
    # the sandbox is torn down even though its in-tree copy is collected, so the
    # link dangles at validation. Drop every absolute-target link (it cannot
    # survive teardown) and every already-dangling relative one, leaving the
    # datadirs + server logs collectable for post-failure debugging.
    find "$tap_out" -type l 2>/dev/null | while read -r __l; do
        case "$(readlink "$__l" 2>/dev/null)" in
            /*) rm -f "$__l" ;;
            *) [ -e "$__l" ] || rm -f "$__l" ;;
        esac
    done
    if [ "$found" != 1 ]; then
        echo "SKIP: no t/*.pl matched under $srcdir (suite=$suite, tap_file=${tap_file:-*})" >&2
        exit 0
    fi
    exit "$rc"
fi

# ---- oracle-mode initdb template (IvorySQL) ----
# pg_regress --temp-instance clones $INITDB_TEMPLATE only when NOT given
# --no-locale (else it runs its own initdb -m pg, the wrong mode). So for an
# oracle-mode suite, build the template here with initdb -m oracle [-C normal]
# and export INITDB_TEMPLATE; the codegen omits --no-locale for oracle so the
# clone is honored. C locale is baked via initdb's OWN --no-locale + the ambient
# LC_ALL=C. The mode lives in the cloned cluster, so this is binary-agnostic.
if [ "$initdb_mode" = "oracle" ]; then
  ORA_TEMPLATE="$TEST_TMPDIR/initdb-template-oracle"
  rm -rf "$ORA_TEMPLATE"
  ora_initdb_args="--auth=trust --no-sync --no-instructions --lc-messages=C --no-locale -m oracle"
  [ -n "$initdb_compat" ] && ora_initdb_args="$ora_initdb_args -C $initdb_compat"
  echo "== building oracle-mode initdb template ($ora_initdb_args) ==" >&2
  # shellcheck disable=SC2086  # intentional word-split of the assembled flags
  if ! "$PGROOT/bin/initdb" $ora_initdb_args "$ORA_TEMPLATE" > "$TEST_TMPDIR/initdb-template.log" 2>&1; then
    echo "ERROR: oracle-mode initdb failed; see below" >&2
    cat "$TEST_TMPDIR/initdb-template.log" >&2 || true
    exit 1
  fi
  export INITDB_TEMPLATE="$ORA_TEMPLATE"
fi

# ---- invocation ----
OUT="${TEST_UNDECLARED_OUTPUTS_DIR:-$TEST_TMPDIR/out}/${suite:-$kind}"
mkdir -p "$OUT"
TMPINST="$TEST_TMPDIR/inst-${suite:-$kind}"
# Short socket dir: the runfiles/TEST_TMPDIR paths exceed sun_path (107).
SOCK="$(mktemp -d /tmp/pgr.XXXXXX 2>/dev/null || mktemp -d)"

set -- \
  --bindir="$PGROOT/bin" \
  --inputdir="$srcdir" \
  --outputdir="$OUT" \
  --temp-instance="$TMPINST" \
  --port=5432 \
  --dbname="$dbname"
# --expecteddir exists only in PG16+ pg_regress (older keeps `expected/` under
# --inputdir). Detect it from the binary, not the version string: flavor
# versions (e.g. openHalo's "1beta1", which is the PG14 line) do not map to a PG
# version number, so a numeric compare misfires. `pg_regress --help` advertises
# the flag iff the binary supports it (the closure is populated by here, so the
# dynamic binary runs).
# PG16+ reads expected/ via --expecteddir; point it at the source tree's
# expected/ so it resolves regardless of where <inputdir> ends up.
expecteddir="$srcdir"
if "$runner" --help 2>&1 | grep -q -- '--expecteddir'; then
  set -- "$@" --expecteddir="$expecteddir"
fi
# PG<=14 pg_regress (the openHalo base) does NOT create the @testtablespace@
# dir on its own: it gates that on --make-testtablespace-dir (default off), so
# the core `tablespace` suite's CREATE TABLESPACE ... LOCATION '@testtablespace@'
# fails "directory does not exist" outside a make/meson run. PG>=15 dropped the
# flag (it uses in-place tablespaces, LOCATION ''). Pass it iff the runner
# advertises it (same self-detect as --expecteddir above).
if "$runner" --help 2>&1 | grep -q -- '--make-testtablespace-dir'; then
  set -- "$@" --make-testtablespace-dir
fi
# --encoding / --no-locale are NOT decided here: the codegen threads each suite's
# exact pg_regress value-flags (--encoding, --no-locale, --load-extension,
# --create-role) through --regress-opt, so they are appended verbatim below. The
# harness stays a faithful executor of the introspect cmd rather than re-deriving
# locale/encoding policy. (Oracle mode's C locale is baked into its template; the
# codegen omits --no-locale for it.)
# --temp-config appends a postgresql.conf overlay to the temp instance (e.g.
# shared_preload_libraries for pg_stat_statements, wal_level for test_decoding).
[ -n "$temp_config" ] && set -- "$@" --temp-config="$temp_config"
# shellcheck disable=SC2086  # intentional word-split: each --regress-opt is one token
[ -n "$regress_opts" ] && set -- "$@" $regress_opts
[ -n "$dlpath" ] && set -- "$@" --dlpath="$dlpath"
[ -n "$max_conc" ] && set -- "$@" --max-concurrent-tests="$max_conc"

if [ -n "$schedule" ]; then
  sched_path="$srcdir/$schedule"
  # Drop known fork-divergent specs from a schedule-driven suite at run time.
  # The codegen emits one target for the whole schedule and cannot remove a
  # single test, so when --exclude-tests is given the harness copies the
  # schedule and strips those specs: remove each name as a whole word from every
  # `test:` line, then delete any `test:` line left with no specs (isolation
  # schedules list one spec per line; a multi-spec parallel_schedule line just
  # loses the token). Every other test still runs. Motivating case: openHalo
  # isolation `timeouts`, whose lock_timeout divergence hangs that one spec.
  if [ -n "$exclude_tests" ]; then
    filtered="$TEST_TMPDIR/schedule-${suite:-$kind}"
    cp "$sched_path" "$filtered"
    # shellcheck disable=SC2086  # intentional word-split: space-separated names
    for t in $exclude_tests; do
      sed -i -E -e "/^test:/ s/(^|[[:space:]])$t([[:space:]]|\$)/\1\2/g" \
        -e "/^test:[[:space:]]*\$/d" "$filtered"
    done
    echo "   excluded from schedule: $exclude_tests" >&2
    sched_path="$filtered"
  fi
  set -- "$@" --schedule="$sched_path"
elif [ -n "$tests" ]; then
  # shellcheck disable=SC2086
  set -- "$@" $tests
else
  echo "ERROR: neither --schedule nor --tests given for suite=$suite" >&2
  exit 1
fi

echo "== ${kind} suite=${suite:-?} v=${version:-?}/${flavor:-?}/${optset:-?} ==" >&2
echo "   runner=$runner" >&2
echo "   srcdir=$srcdir sock=$SOCK dlpath=${dlpath:-<none>} ==" >&2

# contrib `\copy` uses paths relative to the suite dir; outputdir/temp-instance/
# socket are absolute, so changing CWD is safe.
if [ -n "$run_cwd" ]; then
  cd "$run_cwd"
fi

set +e
# PGHOST/PGPORT: the temp instance listens only on the $SOCK unix socket; export
# them so pg_regress's sessions AND the inner libpq loopback connections that
# postgres_fdw/dblink open (no host -> default socket dir) reach this instance.
PGHOST="$SOCK" PGPORT=5432 PG_REGRESS_SOCK_DIR="$SOCK" "$runner" "$@" >&2 2>&1
rc=$?
set -e

# Collect artifacts for Bazel's outputs.zip.
if [ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]; then
  cp -f "$OUT/regression.diffs" "$TEST_UNDECLARED_OUTPUTS_DIR/" 2>/dev/null || true
  cp -f "$OUT/regression.out" "$TEST_UNDECLARED_OUTPUTS_DIR/" 2>/dev/null || true
fi

# Accept a known fork golden diff that is PURELY cosmetic psql table rendering:
# leading + trailing whitespace (psql CENTERS column headers and pads cells, so
# a column-width change shifts both) and separator dash/plus width. NO data
# content differs. The multiset of normalized removed vs added diff lines must
# be EQUAL: a real difference is a content line that does not normalize away, so
# the multisets stay unequal and the failure stands. Safe because it is opt-in
# per suite via --golden-cosmetic (e.g. openHalo postgres_fdw, whose EXPLAIN
# QUERY PLAN column renders at a different width than upstream).
if [ "$rc" -ne 0 ] && [ -n "$golden_cosmetic" ] && [ -s "$OUT/regression.diffs" ]; then
  # drop the diff marker; strip leading + trailing whitespace; collapse a
  # separator line (only dashes/pluses) to a constant so its width is ignored.
  _cosm='s/^.//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^[-+]{3,}$/SEP/'
  removed="$(grep '^-' "$OUT/regression.diffs" | grep -v '^--- ' | sed -E "$_cosm" | sort)"
  added="$(grep '^+' "$OUT/regression.diffs" | grep -v '^+++ ' | sed -E "$_cosm" | sort)"
  if [ "$removed" = "$added" ]; then
    echo "== golden-cosmetic: accepted suite=${suite:-$kind} (psql table-rendering diff only) ==" >&2
    rc=0
  fi
fi

if [ "$rc" -ne 0 ]; then
  echo "== regression.diffs (rc=$rc) ==" >&2
  cat "$OUT/regression.diffs" >&2 2>/dev/null || echo "(no regression.diffs)" >&2
  exit "$rc"
fi
echo "OK: $kind ${suite:-} passed" >&2
