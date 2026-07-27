#!/usr/bin/env python3
"""Synthesize a `test_suites` introspect for an external PGXS extension.

The make-path analog of `pg_build_make_introspect.py`, for extensions: it turns
an extension's own test universe into the same `test_suites` shape the make
flavors emit, so the committed `catalog/extensions/<ext>/introspect/<ext>~<ver>
.json` feeds the existing `_suites_from_test_suites` decoder unchanged and the
catalog `repo.json` carries only customizations, never test names.

The universe is DISCOVERED, never hand-transcribed:

- the regress suite from the extension's `make -n installcheck` dry run (read on
  stdin), which resolves `REGRESS` / `REGRESS_OPTS` exactly -- including any
  Makefile conditionals -- into a single `pg_regress` command line;
- the TAP suite from a `t/*.pl` glob of the source tree;
- the smoke extension names from the installed `*.control` basenames.

Pure-Python stdlib; runs inside the extension-build genrule under the hermetic
rules_python interpreter, exactly like `pg_build_make_introspect.py`.

The resolved `pg_regress` line looks like:

    echo "..." && <pg_regress> --inputdir=./ --bindir='...' --load-extension=age
      --inputdir=.//regress --outputdir=... --temp-instance=... --port=N
      --encoding=UTF-8 --temp-config .//regress/age_regression.conf
      --dbname=contrib_regression scan graphid ... drop

We keep only the options the harness does not manage itself
(`--load-extension` / `--inputdir` / `--encoding` / `--temp-config` /
`--dbname` / `--schedule`) and treat the trailing bare tokens as the regress
test names. Harness-managed options (`--bindir` / `--outputdir` /
`--temp-instance` / `--port` / `--max-concurrent-tests` / `--dlpath` /
`--host`) are dropped; the runner sets its own.
"""

import argparse
import json
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Valued `pg_regress` options meaningful to the discovered suite; each maps to
# the `_Regress` field it populates (`--load-extension` accumulates a list).
_KEEP = {
    "--load-extension": "load_extensions",
    "--inputdir": "inputdir",
    "--encoding": "encoding",
    "--temp-config": "temp_config",
    "--dbname": "dbname",
    "--schedule": "schedule",
}

# Valued `pg_regress` options the harness sets itself; dropped (value consumed).
_DROP = frozenset({
    "--bindir",
    "--outputdir",
    "--temp-instance",
    "--port",
    "--max-concurrent-tests",
    "--dlpath",
    "--host",
})

# Source-relative path fields (normalized against the source root).
_PATH_FIELDS = ("inputdir", "temp_config", "schedule")


@dataclass
class _Regress:
    """The resolved `pg_regress` invocation, split into introspect fields."""

    tests: list[str] = field(default_factory=list)
    load_extensions: list[str] = field(default_factory=list)
    inputdir: str = ""
    encoding: str = ""
    temp_config: str = ""
    dbname: str = ""
    schedule: str = ""


def _normalize_srcrel(path: str, src_dir: Path) -> str:
    """Normalize a `pg_regress` path option value relative to the source root.

    The make ran with `-C <src_dir>`, so its `.` is the source root. Collapse
    `//`, strip a leading `./` (`.//regress` -> `regress`). An absolute path is
    kept only when it lives under the source tree (stripped to a source-relative
    path); otherwise it is dropped. A Makefile that resolves an option through a
    make variable rooted at the INSTALLED pgxs tree (e.g. pg_stat_monitor's
    `--temp-config $(...)/pg_stat_monitor.conf`) yields a path outside the
    committed source and, worse, an execroot-absolute string that would poison
    the reproducible introspect; such a value is discarded here and is instead
    declared as a `repo.json` `test_overrides` customization.
    """
    if not path:
        return ""
    while "//" in path:
        path = path.replace("//", "/")
    path = path.removeprefix("./")
    if path.startswith("/"):
        root = str(src_dir).rstrip("/") + "/"
        return path[len(root) :] if path.startswith(root) else ""
    return path


def _regress_line_tokens(text: str) -> list[str] | None:
    """Return the `pg_regress` argument tokens from the dry-run output.

    Finds the recipe line carrying the `pg_regress` invocation and returns the
    tokens after the binary; `None` when there is no such line.
    """
    for line in text.splitlines():
        if "pg_regress" not in line:
            continue
        parts = shlex.split(line)
        for i, tok in enumerate(parts):
            if tok == "pg_regress" or tok.endswith("/pg_regress"):
                return parts[i + 1 :]
    return None


def _parse_installcheck(text: str, src_dir: Path) -> _Regress | None:
    """Parse the `make -n installcheck` dry run into a `_Regress`, or `None`."""
    tokens = _regress_line_tokens(text)
    if tokens is None:
        return None

    reg = _Regress()
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if not tok.startswith("--"):
            reg.tests.append(tok)
            i += 1
            continue
        if "=" in tok:
            opt, value = tok.split("=", 1)
            i += 1
        elif tok in _KEEP or tok in _DROP:
            opt = tok
            value = tokens[i + 1] if i + 1 < len(tokens) else ""
            i += 2
        else:
            # An unknown flag is assumed valueless (matches nothing we keep).
            i += 1
            continue
        if opt == "--load-extension":
            reg.load_extensions.append(value)
        elif opt in _KEEP:
            setattr(reg, _KEEP[opt], value)
        # a harness-managed or unknown option contributes nothing.

    for name in _PATH_FIELDS:
        setattr(reg, name, _normalize_srcrel(getattr(reg, name), src_dir))
    return reg


# Base-version spec a discovered `tests` list applies to. A single build sees
# one PG major, so it cannot know whether the upstream test list varies by
# major; it emits the version-agnostic wildcard, meaning "attempt on every
# compatible base version". When an extension's list DOES vary by major (its
# `REGRESS` embeds `$(MAJORVERSION)`), a cross-major merge step keeps the shared
# tests under `"*"` and splits the differing ones into per-major range specs
# (e.g. `">=16,<17"` / `">=17,<18"` / `">=18"`); the consumer
# (`schema.bzl::_suites_from_metadata_test`) unions `"*"` with each range spec
# matching the base version being rendered.
_SPEC_ALL = "*"


def _by_version(names: list[str]) -> dict[str, list[str]]:
    """Wrap a discovered test list in the version-spec-keyed `tests` map."""
    return {_SPEC_ALL: names}


def _regress_suite(reg: _Regress | None) -> dict[str, object] | None:
    """Build the ordered regress SuiteDecl, or `None` when it has no content."""
    if reg is None or (not reg.tests and not reg.schedule):
        return None
    decl: dict[str, object] = {
        "slug": "regress",
        "kind": "regress",
        # NOTE: each spec's `tests` list is kept in pg_regress EXECUTION order,
        # never sorted: the suite runs the tests in this order and they depend
        # on it (a setup test comes first, `drop` tears the extension down
        # last). Thus the order is deterministic since it is the resolved
        # Makefile `REGRESS` sequence. `sort_keys` at emit time sorts only the
        # object keys (including the spec keys), not these lists.
        "tests": _by_version(reg.tests),
    }
    # Optional fields, emitted only when set (the emit sorts the object keys).
    optional: list[tuple[str, object]] = [
        ("schedule", reg.schedule),
        ("inputdir", reg.inputdir),
        ("load_extensions", reg.load_extensions),
        ("encoding", reg.encoding),
        ("temp_config", reg.temp_config),
        ("dbname", reg.dbname),
    ]
    decl.update((key, value) for key, value in optional if value)
    return decl


def _stems(src_dir: Path, pattern: str) -> list[str]:
    """Sorted basenames (final suffix stripped) matching `src_dir/pattern`."""
    return sorted(path.stem for path in src_dir.glob(pattern))


def _introspect(text: str, src_dir: Path) -> dict[str, object]:
    """Assemble the full `test_suites` introspect from the make dry run."""
    suites: list[dict[str, object]] = []
    regress = _regress_suite(_parse_installcheck(text, src_dir))
    if regress is not None:
        suites.append(regress)

    # TAP: one entry per `t/*.pl`, mirroring the upstream `.pl` basenames.
    pl_names = _stems(src_dir, "t/*.pl")
    if pl_names:
        suites.append(
            {"slug": "tap", "kind": "tap", "tests": _by_version(pl_names)},
        )

    return {
        "version": 1,
        "test_suites": suites,
        # smoke: extension names from the installed `*.control` basenames.
        "controls": _stems(src_dir, "*.control"),
    }


def main() -> int:
    """Read `make -n installcheck` on stdin; write the introspect to `--out`."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--src-dir",
        required=True,
        type=Path,
        help="the extension source copy (Makefile / t/ / *.control root)",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="the introspect JSON to write",
    )
    args = parser.parse_args()

    introspect = _introspect(sys.stdin.read(), args.src_dir)
    # `sort_keys` makes every object key deterministic regardless of build order
    # or insertion order (including the `tests` map's spec keys); the list values
    # (each spec's `tests` execution order) are left as discovered.
    document = json.dumps(introspect, indent=4, sort_keys=True)
    args.out.write_text(document + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
