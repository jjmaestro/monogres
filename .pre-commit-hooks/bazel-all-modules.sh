#!/usr/bin/env bash
#
# Run a Bazel command across every present module (root + submodules). Meant
# to run inside the dev container (invoked via `make -C build/docker
# exec-image`); pass the bazel subcommand and its args, e.g.
#
#   bazel-all-modules.sh query //...            # loading-phase check (cheapest)
#   bazel-all-modules.sh build --nobuild //...  # analysis-phase smoke
#   bazel-all-modules.sh test //...             # full test suite
#
# A leading `--strict` flag treats known actionable Bazel warnings as errors:
# it forces `--lockfile_mode=off` (so module extensions re-evaluate) and fails
# any module whose output flags a stale apt lock, live resolution, or use_repo
# drift (`bazel mod tidy`). Off by default, so normal runs never break but
# testing can enforce stricter checks:
#
#   bazel-all-modules.sh --strict build --nobuild //...

set -uo pipefail

STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
  STRICT=1
  shift
fi

if [[ ${#} -eq 0 ]]; then
  echo "usage: ${0##*/} [--strict] <bazel-command> [args...]" >&2
  echo "  e.g. ${0##*/} test //...  |  ${0##*/} --strict build --nobuild //..." >&2
  exit 2
fi

# In --strict mode these warnings are promoted to errors (off by default),
# joined into a single grep -E alternation:
STRICT_WARN_PATTERNS=(
  # monoext apt-lock staleness -> silent fallback to live resolution
  'is stale'
  'Falling back to live resolution'
  'Resolving live'
  'No apt lockfile'
  # stale use_repo set (Bazel only hints "bazel mod tidy")
  'bazel mod tidy'
)
STRICT_WARN_RE="$(IFS='|'; printf '%s' "${STRICT_WARN_PATTERNS[*]}")"

MODULE=(
  .
  docs
  starlark_utils
  starlark_utils/examples
  starlark_utils/docs
  sysroots
  sysroots/examples
  third_party/antlr
  tests
  examples
  e2e
  e2e/smoke
)

MODULE_NAME="$(
  grep -A1 -E "module\(" MODULE.bazel | xargs |
    tr -d "," | awk '{print $NF}'
)"

FAILED=()

for module in "${MODULE[@]}"; do
  [[ -f "${module}/MODULE.bazel" ]] || continue

  # NOTE:
  # Skipping docs for Bazel 8 because it adds 'load()' statements.
  [[ "${module}" == "docs" ]] && bazel --version | grep -q 'bazel 8.' && continue

  pushd "${module}" > /dev/null || continue

  echo
  if [[ "${module}" == "." ]]; then
    echo "--- [${MODULE_NAME}] bazel ${*}"
  else
    echo "--- [${MODULE_NAME}/${module}] bazel ${*}"
  fi
  echo

  # NOTE:
  # "no (test) targets" error (exit code 4) is allowed.
  # See the Bazel wrapper in tools/bazel
  #
  # `--batch` (a startup option, so it precedes the command) runs without a
  # persistent server. A hook is something a developer interrupts, and a server
  # outlives the client that started it: the next run then blocks on the output
  # base lock reporting only "Waiting for it to complete...", with nothing to say
  # which process holds it. Server-less, there is one process tree to kill.
  if [[ "${STRICT}" == "1" ]]; then
    # Force extension re-evaluation so the strict warnings surface, capture
    # stderr, and treat a matching warning as a failure.
    stderr_log="$(mktemp)"
    if bazel --batch "${@}" --lockfile_mode=off 2> "${stderr_log}"; then
      cat "${stderr_log}" >&2
      if grep -qE "${STRICT_WARN_RE}" "${stderr_log}"; then
        echo "STRICT: promoting warnings to errors in ${module}:" >&2
        grep -nE "${STRICT_WARN_RE}" "${stderr_log}" >&2
        FAILED+=("${module}")
      fi
    else
      cat "${stderr_log}" >&2
      FAILED+=("${module}")
    fi
    rm -f "${stderr_log}"
  elif ! bazel --batch "${@}"; then
    FAILED+=("${module}")
  fi

  popd > /dev/null || continue
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo
  echo "FAILED modules: ${FAILED[*]}"
  exit 1
fi
