#!/usr/bin/env bash
# shellcheck disable=SC2250,SC2292,SC2312
#
# compare-install-trees.sh MESON_ROOT OVERLAY_ROOT [OUTDIR]
#
# Validate the native Bazel cc_* Postgres install tree against the meson /
# rules_foreign_cc build it replaces. Two questions:
#
#   1. Manifest parity: same set of installed paths? What is only in one side
#      (the overlay deliberately defers static archives, pgxs, pkg-config), and
#      is anything shipped by the overlay that meson does not ship?
#   2. Content parity: for paths present on both sides, are the bytes identical?
#      Where they differ, why (build-id, embedded build paths, link order), and
#      could they be made reproducible?
#
# Portable to busybox or GNU coreutils: no `find -printf`, no `file`, no
# binutils. ELF is detected by magic bytes; embedded absolute paths (the usual
# cause of binary divergence: __FILE__, DW_AT_comp_dir) are extracted with
# `grep -a`.
set -u

A_IN="${1:?meson tree root}"
B_IN="${2:?overlay tree root}"
OUT="${3:-/tmp/pgcmp}"
rm -rf "$OUT"
mkdir -p "$OUT"

# The two trees may carry different install prefixes (e.g. a /postgres/<v>/
# subdir vs files at the root). Root each at the directory that owns `bin/`, so
# the comparison is over install-relative paths and a prefix shift does not read
# as a total mismatch.
detect_root() {
    local t="$1" d
    d=$(find "$t" -type d -name bin 2>/dev/null | sort | head -1)
    if [ -n "$d" ]; then dirname "$d"; else echo "$t"; fi
}
A=$(detect_root "$A_IN")
B=$(detect_root "$B_IN")
echo "meson   install root: $A"
echo "overlay install root: $B"
echo

# Per-tree manifests: a sorted list of regular files, a sorted list of symlinks,
# a `<sha>\t<path>` table for files, and a `<path>\t<target>` table for links.
gen_manifest() {
    local root="$1" pre="$2" f s t
    (cd "$root" && find . -type f 2>/dev/null | sed 's#^\./##' | sort) >"$OUT/$pre.files"
    (cd "$root" && find . -type l 2>/dev/null | sed 's#^\./##' | sort) >"$OUT/$pre.links"
    sort -u "$OUT/$pre.files" "$OUT/$pre.links" >"$OUT/$pre.all"
    : >"$OUT/$pre.sha"
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        s=$(sha256sum "$root/$f" | awk '{print $1}')
        printf '%s\t%s\n' "$s" "$f" >>"$OUT/$pre.sha"
    done <"$OUT/$pre.files"
    : >"$OUT/$pre.linktgt"
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        t=$(readlink "$root/$f")
        printf '%s\t%s\n' "$f" "$t" >>"$OUT/$pre.linktgt"
    done <"$OUT/$pre.links"
}
echo "Scanning meson tree ..."
gen_manifest "$A" meson
echo "Scanning overlay tree ..."
gen_manifest "$B" overlay

# ---------------------------------------------------------------------------
# Part 1: manifest parity (path presence, ignoring file-vs-symlink type).
# ---------------------------------------------------------------------------
comm -23 "$OUT/meson.all" "$OUT/overlay.all" >"$OUT/only_meson"
comm -13 "$OUT/meson.all" "$OUT/overlay.all" >"$OUT/only_overlay"
comm -12 "$OUT/meson.all" "$OUT/overlay.all" >"$OUT/both"

echo
echo "==================== PART 1: MANIFEST PARITY ===================="
printf 'meson paths      : %s\n' "$(wc -l <"$OUT/meson.all")"
printf 'overlay paths    : %s\n' "$(wc -l <"$OUT/overlay.all")"
printf 'in both          : %s\n' "$(wc -l <"$OUT/both")"
printf 'only in meson    : %s\n' "$(wc -l <"$OUT/only_meson")"
printf 'only in overlay  : %s\n' "$(wc -l <"$OUT/only_overlay")"

# Bucket the only-in-meson set against the documented overlay deferrals.
echo
echo "--- only in meson, bucketed (expected = deferred families) ---"
awk '
    /\.a$/                      { a["static archive (.a)"]++; next }
    /^lib\/pgxs\//              { a["pgxs build infra (lib/pgxs/)"]++; next }
    /\.pc$/                     { a["pkg-config (.pc)"]++; next }
    /Makefile/                  { a["Makefile fragment"]++; next }
                                { a["OTHER (investigate)"]++; o[NR]=$0 }
    END {
        for (k in a) printf "  %5d  %s\n", a[k], k
        if (length(o)) { print "  --- OTHER entries: ---"; for (i in o) print "      " o[i] }
    }
' "$OUT/only_meson" | sort -k1 -rn

echo
echo "--- only in overlay (should be empty; anything here we ship that meson does not) ---"
if [ -s "$OUT/only_overlay" ]; then sed 's/^/  /' "$OUT/only_overlay"; else echo "  (none)"; fi

# File-vs-symlink type mismatches among shared paths (e.g. pg_config.h: a real
# copy in meson include/, a within-tree symlink in the overlay).
echo
echo "--- type mismatches (regular file on one side, symlink on the other) ---"
comm -12 "$OUT/meson.files" "$OUT/overlay.links" | sed 's/^/  meson=file overlay=link  /' >"$OUT/typemism"
comm -12 "$OUT/meson.links" "$OUT/overlay.files" | sed 's/^/  meson=link overlay=file  /' >>"$OUT/typemism"
if [ -s "$OUT/typemism" ]; then cat "$OUT/typemism"; else echo "  (none)"; fi

# ---------------------------------------------------------------------------
# Part 2: content parity for paths that are regular files on both sides.
# ---------------------------------------------------------------------------
comm -12 "$OUT/meson.files" "$OUT/overlay.files" >"$OUT/both.files"

is_elf() {
    [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
}
elf_paths() {
    grep -a -o '/[A-Za-z0-9_][A-Za-z0-9_./+-]\{3,\}' "$1" 2>/dev/null | sort -u
}

identical=0
differ=0
: >"$OUT/differ"
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if cmp -s "$A/$f" "$B/$f"; then
        identical=$((identical + 1))
    else
        differ=$((differ + 1))
        echo "$f" >>"$OUT/differ"
    fi
done <"$OUT/both.files"

echo
echo "==================== PART 2: CONTENT PARITY ===================="
printf 'regular files on both sides : %s\n' "$(wc -l <"$OUT/both.files")"
printf 'byte-identical              : %s\n' "$identical"
printf 'differing                   : %s\n' "$differ"

# Classify differing files: ELF vs by-extension.
echo
echo "--- differing files, classified ---"
: >"$OUT/differ.elf"
: >"$OUT/differ.other"
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if is_elf "$A/$f"; then echo "$f" >>"$OUT/differ.elf"; else echo "$f" >>"$OUT/differ.other"; fi
done <"$OUT/differ"
printf '  ELF (binaries/.so) : %s\n' "$(wc -l <"$OUT/differ.elf")"
printf '  non-ELF            : %s\n' "$(wc -l <"$OUT/differ.other")"
if [ -s "$OUT/differ.other" ]; then
    echo "  non-ELF differing (by extension):"
    awk -F. 'NF>1{print $NF} NF<=1{print "(noext)"}' "$OUT/differ.other" | sort | uniq -c | sed 's/^/    /'
    echo "  non-ELF differing list:"
    sed 's/^/    /' "$OUT/differ.other"
fi

# For each differing ELF: how many bytes differ, where the first diff is, and
# the embedded absolute-path strings unique to each side (the build-dir
# fingerprint that drives binary non-determinism).
echo
echo "--- differing ELF detail (byte delta + embedded build-path fingerprint) ---"
: >"$OUT/elf_paths_only_meson"
: >"$OUT/elf_paths_only_overlay"
while IFS= read -r f; do
    [ -z "$f" ] && continue
    sa=$(stat -c %s "$A/$f" 2>/dev/null)
    sb=$(stat -c %s "$B/$f" 2>/dev/null)
    nbytes=$(cmp -l "$A/$f" "$B/$f" 2>/dev/null | wc -l)
    firstoff=$(cmp "$A/$f" "$B/$f" 2>&1 | head -1)
    printf '  %-48s meson=%-9s overlay=%-9s diffbytes=%-8s %s\n' "$f" "$sa" "$sb" "$nbytes" "$firstoff"
    elf_paths "$A/$f" >"$OUT/.pa"
    elf_paths "$B/$f" >"$OUT/.pb"
    comm -23 "$OUT/.pa" "$OUT/.pb" >>"$OUT/elf_paths_only_meson"
    comm -13 "$OUT/.pa" "$OUT/.pb" >>"$OUT/elf_paths_only_overlay"
done <"$OUT/differ.elf"

# Aggregate the distinct path roots (first 4 components) embedded in one build
# but not the other: the smoking gun for build-dir divergence.
echo
echo "--- embedded path roots present ONLY in meson binaries (top 20) ---"
awk -F/ '{print "/" $2 "/" $3 "/" $4 "/" $5}' "$OUT/elf_paths_only_meson" | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'
echo
echo "--- embedded path roots present ONLY in overlay binaries (top 20) ---"
awk -F/ '{print "/" $2 "/" $3 "/" $4 "/" $5}' "$OUT/elf_paths_only_overlay" | sort | uniq -c | sort -rn | head -20 | sed 's/^/  /'

# ---------------------------------------------------------------------------
# Symlink target parity among shared symlinks.
# ---------------------------------------------------------------------------
comm -12 "$OUT/meson.links" "$OUT/overlay.links" >"$OUT/both.links"
echo
echo "--- symlink target differences (paths that are symlinks on both sides) ---"
: >"$OUT/link_target_diff"
while IFS= read -r f; do
    [ -z "$f" ] && continue
    ta=$(readlink "$A/$f")
    tb=$(readlink "$B/$f")
    [ "$ta" = "$tb" ] || printf '  %s : meson=%s overlay=%s\n' "$f" "$ta" "$tb" >>"$OUT/link_target_diff"
done <"$OUT/both.links"
if [ -s "$OUT/link_target_diff" ]; then cat "$OUT/link_target_diff"; else echo "  (all shared symlinks point to the same target)"; fi

echo
echo "==================== DONE ===================="
echo "Artifacts in $OUT:"
echo "  only_meson / only_overlay / both        : manifest sets"
echo "  differ / differ.elf / differ.other      : content-differing files"
echo "  elf_paths_only_{meson,overlay}          : embedded paths unique to each build"
echo "  meson.sha / overlay.sha                 : per-file sha256 tables"
