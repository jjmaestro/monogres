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
import sys
from pathlib import Path

_PATH_BOUNDARY_CHARS = frozenset({"", "-", "."})


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

    return {
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
    }


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
