#!/usr/bin/env python3
"""Synthesize a meson-shape introspect JSON for an autoconf+make PG build.

For meson flavors, `meson introspect` produces a comprehensive JSON used by
Layer 2 (`pg_introspect_version_repo`) to extract contrib names, installed
paths, features, and meson options. Make flavors have no equivalent.

This script walks a post-`make install` tree plus the build-time source tree
and synthesizes the subset of the meson `--introspect` shape that Layer 2 and
gen_contrib consume:

- `buildoptions`: just `prefix` (used by `_get_installed_paths`).
- `buildsystem_files`: synthesized `contrib/<name>/Makefile` entries (used
  by `get_contrib_names`).
- `installed`: build_path -> install_path map. Build paths are synthesized
  relative paths matching meson's convention (`contrib/<name>/<basename>`
  for contribs, `src/backend/<basename>` for non-contrib files). Install
  paths preserve the make-build layout (`share/postgresql/extension/...`,
  `lib/postgresql/...`) so the downstream contrib `:tar` packages files at
  their real install locations.
- `targets`: a hardcoded `bin@run` entry pointing at `src/backend/postgres`
  (the real PG source path for the postgres binary). Layer 2's
  `_build_path_prefixes` reads `filename` + `defined_in` from this entry to
  derive the source-tree-relative postgres target path. If PG ever moves
  the binary or renames it (extremely unlikely upstream), this hardcoded
  fallback would drift — re-check after any major PG version bump that
  changes the binary location.
- `test_suites`: version-exact, option-set-gated regression/isolation suite
  introspect (the make analog of meson's `.tests`); see `_synth_test_suites`.

Pure-Python stdlib; runs inside the `pg_build_make` genrule's shell with the
hermetic rules_python interpreter.

## Non-obvious behaviors

- **`contrib/contrib/` filter** (`_list_contrib_dirs`): a literal `contrib`
  directory nested under PG's contrib root can only come from a source-tree
  merge misconfiguration (no real PG contrib is named `contrib`); skip it
  rather than emitting nonsense contrib data.

- **`_PATH_BOUNDARY_CHARS` heuristic** (`_owner_for`): when an installed
  file's basename isn't in the source tree as-is (e.g. versioned SQL
  files like `hstore--1.7--1.8.sql` are generated at install time), the
  longest-contrib-name-prefix match attributes ownership. The boundary
  char check (next char must be `""`, `-`, or `.`) prevents `hstore`
  from incorrectly claiming `hstore_plperl.so`.

- **Duplicate-basename warning** (`synth`): if two contribs ship files
  with the same basename, first-write-wins on the `installed` dict. A
  WARNING is logged to stderr so the duplicate doesn't go silent.

- **Filter contribs with no installed files** (`synth`): a contrib source
  dir can exist while `make install` emits nothing for it (configure-time
  feature gates skip e.g. the plperl transform contribs when perl is
  disabled). Such contribs are dropped from `buildsystem_files` so Layer
  2's `validate_contrib_paths` doesn't fail on empty path lists.
"""

import argparse
import json
import re
import sys
from pathlib import Path

_PATH_BOUNDARY_CHARS = frozenset({"", "-", "."})

# Match `requires = '...'` / `requires = "..."` / `requires = bareword` in a
# `.control` file. Same accepted forms as `gen_pg_introspect_jsons.py`'s
# meson-side walk (which defers to the `contrib_requires` emitted here when
# present, since only this script sees the MERGED tree with overlay contribs).
_REQUIRES_RE = re.compile(
    r"""
    ^\s*requires\s*=\s*       # the key
    (?:
        '(?P<sq>[^']*)'       # single-quoted
        | "(?P<dq>[^"]*)"     # double-quoted
        | (?P<bare>\S+)       # bareword (no spaces, no commas)
    )
    \s*(?:\#.*)?$             # optional trailing # comment
    """,
    re.VERBOSE | re.MULTILINE,
)


def _parse_requires(content: str) -> list[str]:
    """Parse the `requires` directive from a `.control` file's contents."""
    matches = list(_REQUIRES_RE.finditer(content))
    if not matches:
        return []
    last = matches[-1]
    raw = last.group("sq") or last.group("dq") or last.group("bare") or ""
    if not raw.strip():
        return []
    parts = [p.strip() for p in raw.split(",")]
    return sorted({p for p in parts if p})


def _walk_contrib_requires(
    workdir: Path,
    contrib_names: list[str],
) -> dict[str, list[str]]:
    """Map contrib name -> sorted `.control requires` list (skip-on-empty).

    Walks the MERGED source tree, so overlay contribs (merged in before
    configure ran) contribute their requires too — something a primary-tree
    walk at JSON-generation time cannot see.
    """
    out: dict[str, list[str]] = {}
    for name in contrib_names:
        sub = workdir / "contrib" / name
        reqs: set[str] = set()
        for control in sorted(sub.glob("*.control")):
            try:
                content = control.read_text(errors="replace")
            except OSError:
                continue
            reqs.update(_parse_requires(content))
        if reqs:
            out[name] = sorted(reqs)
    return out


def _list_contrib_dirs(workdir: Path) -> list[str]:
    """Return sorted contrib names from `<workdir>/contrib/*/Makefile`.

    Filters out the literal name `contrib` — that can only come from a
    source-tree merge misconfiguration nesting a tree under PG's contrib
    root; a real PG contrib would never be named `contrib`.
    """
    contrib_root = workdir / "contrib"
    if not contrib_root.is_dir():
        return []
    return sorted(
        d.name
        for d in contrib_root.iterdir()
        if d.is_dir() and d.name != "contrib" and (d / "Makefile").is_file()
    )


def _build_owner_index(workdir: Path, contrib_names: list[str]) -> dict[str, str]:
    """Map install-side basename -> owning contrib name.

    For each contrib's source dir, enumerate basenames present after build
    (`.control`, `.so`, `.sql`, `.h`, etc.) and record them as owned by
    that contrib. Gives a reliable install-path -> contrib mapping that
    handles multi-extension contribs (e.g. hstore_plperl ships both
    hstore_plperl.control and hstore_plperlu.control, both owned by
    `hstore_plperl`).
    """
    owner: dict[str, str] = {}
    for name in contrib_names:
        contrib_dir = workdir / "contrib" / name
        for f in contrib_dir.iterdir():
            owner.setdefault(f.name, name)
    return owner


def _owner_for(
    install_rel: str,
    owner_index: dict[str, str],
    contrib_names: list[str],
) -> str | None:
    """Best-effort attribution of an installed file to a contrib.

    Strategy (in order):
      1. Exact basename match in `owner_index` (most reliable; built from
         source-side file enumeration).
      2. Longest-contrib-name-prefix match against the file basename
         (handles versioned SQL files like `hstore--1.7--1.8.sql` whose
         basename isn't in the source tree as such).
      3. None -> attribute to the postgres core, not a contrib.
    """
    basename = Path(install_rel).name

    if basename in owner_index:
        return owner_index[basename]

    best = None
    for name in contrib_names:
        if basename.startswith(name) and (best is None or len(name) > len(best)):
            stop = basename[len(name) : len(name) + 1]
            # Boundary check: next char must be a delimiter so `hstore`
            # doesn't claim `hstore_plperl.so`.
            if stop in _PATH_BOUNDARY_CHARS:
                best = name
    return best


def _walk_install(installdir: Path) -> list[str]:
    """Return sorted install-rel paths for every regular file under installdir."""
    return sorted(
        str(f.relative_to(installdir))
        for f in installdir.rglob("*")
        if f.is_file() or f.is_symlink()
    )


# ---------------------------------------------------------------------------
# Test-suites: version-exact, option-set-gated
# ---------------------------------------------------------------------------
#
# `meson introspect` emits a `.tests` array describing every regression /
# isolation suite the configured build can run, gated by the enabled options
# (a PL or contrib that was not built contributes no tests). The make path has
# no such array, so we synthesize an equivalent `test_suites` introspect by reading
# the SAME truth the build itself uses:
#
#   - core regress:   src/test/regress/parallel_schedule  (the runnable order)
#   - core isolation: src/test/isolation/isolation_schedule
#   - each PL built:  src/pl/<dir>/{Makefile,GNUmakefile}  REGRESS / ISOLATION
#   - each contrib built: contrib/<name>/Makefile          REGRESS / ISOLATION
#
# Option-set gating is automatic: PLs/contribs that configure did not build are
# absent from the install tree, so they are never enumerated. The introspect is
# therefore version-exact AND option-set-exact, mirroring meson.
#
# Confirmed (PG15 contrib/PL Makefiles): REGRESS / ISOLATION are single static
# assignments (line-continued); there is no `REGRESS +=` and no Linux-relevant
# conditional append, so a literal read is faithful. From REGRESS_OPTS /
# ISOLATION_OPTS only the `--temp-config <conf>` overlay is parsed (into
# `temp_config_srcrel`, so a make suite rides its OWN source .conf via
# `--temp-config-srcrel`, the same as meson, with no checked-in copy); the other
# OPTS (e.g. postgres_fdw's --load-extension) remain per-suite harness config
# carried by the catalog's `metadata.test_overrides`.
#
# src/test/modules/* suites that meson runs are intentionally omitted: `make
# install` does not install them, so the make harness cannot run them anyway.

# PL slug -> (source makefile relpath, installed .control basename that proves
# the PL was built). plpython's control basename is python-major dependent
# (plpython3u.control on PG >= 11), so it is matched by prefix in
# `_pl_installed` rather than a fixed basename.
_PL_SOURCES = (
    ("plpgsql", "src/pl/plpgsql/src/Makefile", "plpgsql.control"),
    ("plperl", "src/pl/plperl/GNUmakefile", "plperl.control"),
    ("pltcl", "src/pl/tcl/Makefile", "pltcl.control"),
    ("plpython", "src/pl/plpython/Makefile", None),
)


def _makefile_raw_var(makefile: Path, var: str) -> str:
    """Raw RHS of the first `var [:+]?= ...` assignment, or '' if absent.

    Joins backslash line-continuations and strips `#` comments, but does NOT
    tokenize or filter, so `$(...)`-bearing values survive (needed to read
    `REGRESS_OPTS` / `ISOLATION_OPTS`, whose `--temp-config` argument is a
    `$(top_srcdir)/...` path). PG contrib/PL Makefiles assign these once (no
    `+=`), so the first assignment is faithful. '' if absent or unreadable.
    """
    try:
        lines = makefile.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    start = re.compile(r"^\s*" + re.escape(var) + r"\s*[:+]?=\s*(.*)$")
    i, n = 0, len(lines)
    while i < n:
        m = start.match(lines[i])
        if not m:
            i += 1
            continue
        frag = m.group(1)
        chunk: list[str] = []
        while True:
            frag = frag.split("#", 1)[0].rstrip()
            if frag.endswith("\\"):
                chunk.append(frag[:-1])
                i += 1
                if i >= n:
                    break
                frag = lines[i]
            else:
                chunk.append(frag)
                break
        return " ".join(chunk)
    return ""


def _makefile_list_var(makefile: Path, var: str) -> list[str]:
    """Read a make list variable (e.g. `REGRESS`, `ISOLATION`) as tokens.

    Drops tokens that are make variable references (containing `$`) or `k=v`
    assignments. Returns [] if the var is absent or unreadable.
    """
    return [
        tok
        for tok in _makefile_raw_var(makefile, var).split()
        if "$" not in tok and "=" not in tok
    ]


def _makefile_temp_config(makefile: Path, var: str, subtree: str) -> str:
    """Source-root-relative path of a `--temp-config` .conf in `<var>_OPTS`, or ''.

    PG contrib Makefiles pass the temp-config overlay through
    `REGRESS_OPTS` / `ISOLATION_OPTS` (e.g. test_decoding's
    `--temp-config $(top_srcdir)/contrib/test_decoding/logical.conf`). Resolve
    the argument to a path relative to the source root so the harness rides the
    suite's OWN source .conf via `--temp-config-srcrel` (no checked-in copy),
    matching the meson path: `$(top_srcdir)/X` -> `X`, `$(srcdir)/X` ->
    `<subtree>/X`, bare -> `<subtree>/<basename>`.
    """
    toks = _makefile_raw_var(makefile, var + "_OPTS").split()
    for i, tok in enumerate(toks):
        if tok == "--temp-config" and i + 1 < len(toks):
            arg = toks[i + 1]
            for prefix in ("$(top_srcdir)/", "$(top_builddir)/"):
                if arg.startswith(prefix):
                    return arg[len(prefix) :]
            srcdir = "$(srcdir)/"
            if arg.startswith(srcdir):
                return f"{subtree}/{arg[len(srcdir) :]}"
            base = arg.rsplit("/", 1)[-1]
            return f"{subtree}/{base}"
    return ""


def _schedule_tests(schedule: Path) -> list[str]:
    """Ordered test names from a pg_regress schedule file (`test: a b c`)."""
    out: list[str] = []
    try:
        content = schedule.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    for raw in content.splitlines():
        line = raw.strip()
        if line.startswith("test:"):
            out.extend(line[len("test:") :].split())
    return out


def _pl_installed(slug: str, install_basenames: set[str]) -> bool:
    """True if PL `slug` shipped a `.control` into the install tree."""
    if slug == "plpython":
        return any(
            b.startswith("plpython") and b.endswith(".control")
            for b in install_basenames
        )
    control = {s: c for s, _, c in _PL_SOURCES}[slug]
    return control in install_basenames


def _contribs_installed(
    install_paths: list[str],
    owner_index: dict[str, str],
    contrib_names: list[str],
) -> set[str]:
    """Contribs that shipped a real, testable artifact: a `.control` (an
    extension) or a `.so` (a loadable module).

    Each such installed file is attributed to its owning contrib via the same
    `_owner_for` logic used for `installed`, so variant control names
    (hstore_plpython3u.control) AND built module names (test_decoding.so,
    passwordcheck.so, basic_archive.so -- output plugins / preload modules that
    have a REGRESS test but no `.control`) all map. Reduced option sets (contrib
    off) install neither, so a CORE header whose basename prefix-collides with a
    contrib name (core `executor/tablefunc.h` vs the `tablefunc` contrib) does
    NOT make that contrib look installed.
    """
    out: set[str] = set()
    for install_rel in install_paths:
        if install_rel.endswith((".control", ".so")):
            owner = _owner_for(install_rel, owner_index, contrib_names)
            if owner:
                out.add(owner)
    return out


def _makefile_suites(slug: str, makefile: Path, subtree: str) -> list[dict]:
    """The regress/isolation suite decls a contrib/PL Makefile defines.

    `REGRESS` -> a regress suite, `ISOLATION` -> an isolation suite (a slug may
    yield both). `subtree` is the suite's source subtree (the Makefile's
    directory relative to the source root), carried so the codegen mirrors the
    source tree like the meson path. Empty list when the Makefile sets neither.
    """
    out: list[dict] = []
    for kind, var in (("regress", "REGRESS"), ("isolation", "ISOLATION")):
        names = _makefile_list_var(makefile, var)
        if names:
            decl = {"slug": slug, "kind": kind, "subtree": subtree, "tests": names}
            srcrel = _makefile_temp_config(makefile, var, subtree)
            if srcrel:
                decl["temp_config_srcrel"] = srcrel
            out.append(decl)
    return out


_BUILD_CFG_RE = re.compile(r"^(with_[a-z0-9_]+|enable_[a-z0-9_]+)\s*=\s*(.*)$")


def _build_config_env(workdir: Path) -> dict[str, str]:
    """Build-config gates (with_*/enable_*) from the configured Makefile.global.

    TAP scripts branch on these: 002_api.pl checks `$ENV{with_ssl} eq 'openssl'`,
    ssl/ldap/gssapi suites `skip unless $ENV{with_*}`. meson's testwrap exports
    them from its build config (they ride each `.tests[].env`); the make analog
    is `src/Makefile.global`, which configure populates with the resolved values
    (`with_ssl = openssl`, `with_ldap = yes`, an empty value when not built). We
    surface them so each synthesized TAP suite carries the same gates as meson.

    Only short scalar tokens are kept: values carrying a path/make-ref/line
    continuation (`with_temp_install`, `with_system_tzdata`, ...) are dropped, as
    they are build internals no `.pl` reads as a feature gate.
    """
    mg = workdir / "src" / "Makefile.global"
    out: dict[str, str] = {}
    try:
        text = mg.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    for line in text.splitlines():
        m = _BUILD_CFG_RE.match(line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if any(c in val for c in ("\\", "$", "/")):
            continue
        out[key] = val
    return out


def _synth_tap_suites(workdir: Path, install_paths: list[str]) -> list[dict]:
    """Synthesize the TAP suites by walking the source tree.

    Every `src/**/t/` directory holding `*.pl` files is one TAP suite, carrying
    its source subtree, the `.pl` basenames it runs, and the build-config gates
    (`tap_env`) the scripts branch on (the meson path gets all of this from its
    `.tests` array). src/test/modules/* is excluded: `make install` does not
    install those modules, so the harness cannot run them.

    Gated on the build having installed the PostgreSQL::Test driver: only a
    `--enable-tap-tests` (test-variant) build ships it, so a production build
    contributes no TAP suites, mirroring meson's tap_tests-gated registration.
    """
    out: list[dict] = []
    if not any("PostgreSQL/Test/Cluster.pm" in p for p in install_paths):
        return out
    src = workdir / "src"
    if not src.is_dir():
        return out
    tap_env = _build_config_env(workdir)
    for t_dir in sorted(src.rglob("t")):
        if not t_dir.is_dir():
            continue
        suite_dir = t_dir.parent
        subtree = str(suite_dir.relative_to(workdir))
        if subtree.startswith("src/test/modules"):
            continue
        pls = sorted(p.stem for p in t_dir.glob("*.pl"))
        if pls:
            entry = {
                "slug": suite_dir.name,
                "kind": "tap",
                "subtree": subtree,
                "tests": pls,
            }
            if tap_env:
                entry["tap_env"] = tap_env
            out.append(entry)
    return out


def _synth_test_suites(
    workdir: Path,
    contrib_names: list[str],
    install_paths: list[str],
    owner_index: dict[str, str],
) -> list[dict]:
    """Build the version-exact, option-set-gated `test_suites` introspect.

    One entry per (slug, kind): a slug that defines both `REGRESS` and
    `ISOLATION` (e.g. test_decoding, postgres_fdw) yields two entries. Core
    regress/isolation carry their `schedule` basename (the harness drives off
    the schedule file in the source tree); contrib/PL suites carry an inline
    `tests` list (no schedule file). `tests` is order-preserving (schedule /
    REGRESS order is load-bearing for pg_regress). Gating is by install-tree
    presence: a PL/contrib that did not install is never enumerated; a contrib is
    enumerated only when it installed a real artifact, a .control or .so (see
    `_contribs_installed`).
    """
    install_basenames = {Path(p).name for p in install_paths}
    installed_contribs = _contribs_installed(install_paths, owner_index, contrib_names)
    suites: list[dict] = []

    core_regress = workdir / "src/test/regress/parallel_schedule"
    if core_regress.is_file():
        suites.append({
            "slug": "regress",
            "kind": "regress",
            "subtree": "src/test/regress",
            "schedule": "parallel_schedule",
            # the main schedule runs with up to 20 concurrent backends, the
            # same fan-out meson tags with --max-concurrent-tests=20.
            "max_conc": 20,
            "tests": _schedule_tests(core_regress),
        })

    core_isolation = workdir / "src/test/isolation/isolation_schedule"
    if core_isolation.is_file():
        suites.append({
            "slug": "isolation",
            "kind": "isolation",
            "subtree": "src/test/isolation",
            "schedule": "isolation_schedule",
            "tests": _schedule_tests(core_isolation),
        })

    for slug, mk_rel, _control in _PL_SOURCES:
        if _pl_installed(slug, install_basenames):
            # The Makefile's directory is the suite's source subtree (plpgsql's
            # sql/expected live beside its Makefile under src/pl/plpgsql/src),
            # matching what meson's --inputdir yields.
            subtree = str(Path(mk_rel).parent)
            suites.extend(_makefile_suites(slug, workdir / mk_rel, subtree))

    # Skip a contrib whose name only a core header prefix-collided with (it
    # installed neither a .control nor a .so, so it is not really built here).
    for name in contrib_names:
        if name in installed_contribs:
            makefile = workdir / "contrib" / name / "Makefile"
            suites.extend(_makefile_suites(name, makefile, "contrib/" + name))

    # TAP suites are walked from the source tree (not the Makefile introspect),
    # mirroring meson's per-.pl registration; gated on the TAP driver install.
    suites.extend(_synth_tap_suites(workdir, install_paths))

    return suites


def synth(workdir: Path, installdir: Path, prefix: str) -> dict:
    all_contrib_names = _list_contrib_dirs(workdir)
    owner_index = _build_owner_index(workdir, all_contrib_names)

    install_paths = _walk_install(installdir)

    installed: dict[str, str] = {}
    contribs_with_files: set[str] = set()

    for install_rel in install_paths:
        owner = _owner_for(install_rel, owner_index, all_contrib_names)
        basename = Path(install_rel).name

        if owner is not None:
            build_path = f"contrib/{owner}/{basename}"
            contribs_with_files.add(owner)
        elif install_rel == "bin/postgres":
            build_path = "src/backend/postgres"
        else:
            # PG core file with no good source-path mapping; synthesize
            # something that won't collide with contribs. The path doesn't
            # need to be meaningful — only contrib paths are consumed
            # downstream.
            build_path = f"src/{install_rel}"

        # `_get_installed_paths` dedups on install path; multiple contribs
        # generating the same install file is rare for PG core but we err
        # to first-write-wins. Emit a WARNING so the collision is visible
        # in the build log instead of being silently lost.
        #
        # Emit install paths with the `prefix` prepended so they're
        # absolute. Layer 2's `_get_installed_paths` then strips the
        # prefix via `paths.relativize(path_installed, prefix)` — same
        # contract as the meson side.
        install_path = f"{prefix.rstrip('/')}/{install_rel}"
        if build_path in installed:
            existing = installed[build_path]
            if existing != install_path:
                print(
                    f"WARNING: synth-introspect duplicate build_path "
                    f"{build_path!r}: keeping {existing!r}, skipping "
                    f"{install_path!r}. This suggests two contribs ship a "
                    f"file with the same basename — review the owner "
                    f"attribution.",
                    file=sys.stderr,
                )
            continue
        installed[build_path] = install_path

    # Only declare contribs that actually shipped files. A contrib source
    # dir can exist while `make install` emits nothing for it
    # (configure-time feature gates) — Layer 2's `validate_contrib_paths`
    # would (correctly) fail on the empty path lists. Filtering keeps the
    # introspect data consistent with what actually got installed.
    contrib_names = sorted(n for n in all_contrib_names if n in contribs_with_files)

    # Synthesized `bin@run` target so `_build_path_prefixes` finds its
    # filename + defined_in. The postgres binary's source path isn't
    # consumed downstream; the helper just needs something parseable.
    targets = [
        {
            "id": "bin@run",
            "filename": ["src/backend/postgres"],
            "name": "postgres",
            "defined_in": "src/backend/Makefile",
            "type": "executable",
        },
    ]

    # Synthesized buildsystem_files (`/src/contrib/<name>/Makefile`) so
    # `BuildIntrospect.get_contrib_names` can enumerate contribs. The
    # `/src/` prefix matches meson's convention (paths start with a
    # leading `/`) — `get_contrib_names` looks for `/contrib/` substring.
    buildsystem_files = [f"/src/contrib/{name}/Makefile" for name in contrib_names]

    result = {
        "buildoptions": [
            {
                "name": "prefix",
                "value": prefix,
                "section": "core",
                "machine": "host",
                "type": "string",
                "description": "Installation prefix",
            },
        ],
        "buildsystem_files": buildsystem_files,
        "installed": installed,
        "targets": targets,
        "test_suites": _synth_test_suites(
            workdir,
            contrib_names,
            install_paths,
            owner_index,
        ),
    }

    # Per-contrib `.control requires`, from the MERGED tree (overlay contribs
    # included). The catalog generator defers to this key when present.
    contrib_requires = _walk_contrib_requires(workdir, contrib_names)
    if contrib_requires:
        result["contrib_requires"] = contrib_requires

    return result


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--workdir", required=True, type=Path)
    p.add_argument("--installdir", required=True, type=Path)
    p.add_argument("--prefix", required=True, type=str)
    p.add_argument("--out", required=True, type=Path)
    args = p.parse_args()

    result = synth(args.workdir, args.installdir, args.prefix)
    args.out.write_text(json.dumps(result, indent=4, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
