#!/usr/bin/env bash
#
# Runs a built monobot and checks what came out. See //tests:e2e.bzl for why
# this exists and what each shape is for.
set -euo pipefail

APP=
GOLDEN=
EXPECT=
CONFIG_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --golden) GOLDEN="$2"; shift 2 ;;
    --expect) EXPECT="$2"; shift 2 ;;
    # Named only so the gate is built before this runs; nothing reads it.
    --gate) shift 2 ;;
    --config-files) shift; CONFIG_FILES=("$@"); break ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ "${#CONFIG_FILES[@]}" -gt 0 ]] || { echo "no config files given" >&2; exit 2; }

# configDir holds extensions/, so climb out of extensions/<name>/monobot.json.
CONFIG="$(realpath "${CONFIG_FILES[0]}")"
CONFIG_DIR="${CONFIG%/*/*/*}"
APP="$(realpath "${APP}")"

WORK="$(mktemp -d)"
REPO="$(mktemp -d)"
LOG="${TEST_TMPDIR:-/tmp}/monobot.log"
trap 'rm -rf "${WORK}" "${REPO}"' EXIT

status=0
env configDir="${CONFIG_DIR}" workdir="${WORK}" monogresRepo="${REPO}" \
  "${APP}" > "${LOG}" 2>&1 || status=$?

fail() {
  echo "FAIL: $1"
  echo "--- application output ---"
  cat "${LOG}"
  exit 1
}

# The regression this guards. A packaged application that cannot construct its
# own JSON types reports it as a Jackson problem, which reads like bad data
# rather than a bad build, so name what it actually is.
if grep -qE 'InvalidDefinitionException|cannot deserialize|no delegate- or property-based Creator' "${LOG}"; then
  fail "the application could not construct its JSON types: the build dropped the reflection they need"
fi

# Separates "got far enough to matter" from "died on startup", which would
# otherwise pass the check above by producing no output at all.
grep -q 'monobot .* started' "${LOG}" || fail "the application did not start"

# A value that can only be in the output if the config was deserialized into an
# object and its fields read back out. A run that never got that far, or that
# got a half-built object, cannot produce it. monobot reports a failed extension
# and carries on, so the exit status says nothing here and this does.
if [[ -n "${EXPECT}" ]]; then
  grep -qF -- "${EXPECT}" "${LOG}" || fail "expected '${EXPECT}' in the output"
fi

[[ "${status}" -eq 0 ]] || fail "the run exited ${status}"

[[ -n "${GOLDEN}" ]] || exit 0

produced="$(find "${REPO}" -name repo.json -print -quit)"
[[ -n "${produced}" ]] || fail "the scan wrote no repo.json"

# Compared with the shell rather than diff, which a test sandbox need not have.
# Read into variables first: nesting the substitutions inside the test would
# throw away their exit status. Both lose any trailing newline, which is what
# lets the golden keep the repository's end-of-file convention.
produced_json="$(cat "${produced}")"
golden_json="$(cat "${GOLDEN}")"

if [[ "${produced_json}" != "${golden_json}" ]]; then
  echo "FAIL: ${produced} does not match ${GOLDEN}"
  echo "--- produced ---"; cat "${produced}"
  echo "--- expected ---"; cat "${GOLDEN}"
  exit 1
fi
