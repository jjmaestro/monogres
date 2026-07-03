#!/usr/bin/env bash
# shellcheck disable=SC2250,SC2292,SC2312
#
# classify-elf-diff.sh MESON_ROOT CC_ROOT [OUTDIR]
#
# Per-ELF semantic classification of two install trees that compare-install-trees.sh
# reports as byte-differing. For every regular file that is ELF on both sides and
# differs, decide whether the difference is BENIGN (same code, same ABI, same
# compiler; the bytes differ only in build-id / RUNPATH / `.dynstr` / `.dynamic`
# and the section offsets those shift, plus `__FILE__` strings in `.rodata`) or
# whether it needs INVESTIGATION (the normalized instruction stream, the dynamic
# symbol interface, or the compiler differ: a real build divergence).
#
# The decisive signal is the normalized disassembly of the executable sections:
# `objdump -d` with the address column and all `0x` operands / jump targets
# masked. Identical normalized code means the same instructions, only relocated;
# a difference means codegen actually changed (different flags, defines, inlining,
# link order affecting layout-sensitive code).
#
# Requires binutils (readelf, objdump, nm) and coreutils. ELF is detected by
# magic bytes.
set -u

A_IN="${1:?meson tree root}"
B_IN="${2:?cc/overlay tree root}"
OUT="${3:-/tmp/pgelf}"
rm -rf "$OUT"
mkdir -p "$OUT"

detect_root() {
    local t="$1" d
    d=$(find "$t" -type d -name bin 2>/dev/null | sort | head -1)
    if [ -n "$d" ]; then dirname "$d"; else echo "$t"; fi
}
A=$(detect_root "$A_IN")
B=$(detect_root "$B_IN")
echo "meson install root: $A"
echo "cc    install root: $B"
echo

is_elf() {
    [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
}

# Emit one `<function>\t<normalized instruction>` record per disassembled
# instruction. Normalization removes everything a pure relocation perturbs: the
# leading address column, `0x...` immediates/displacements, and the absolute
# target address that precedes a `<sym+0x..>` call/jump operand. The function
# label survives as the record key, so the stream can be compared two ways:
#   - as emitted (address order): catches any code or layout change;
#   - sorted by the whole record (name then body): order-independent, so a pure
#     link-order reshuffle collapses to equality. Sorting by the full record (not
#     the name alone) also canonicalizes duplicate static-symbol names whose
#     distinct bodies the linker emits in either order across two builds.
func_stream() {
    objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk '
        /^[0-9a-f]+ <.*>:$/ { cur = $0; sub(/^[0-9a-f]+ </, "", cur); sub(/>:$/, "", cur); next }
        /^[[:space:]]*[0-9a-f]+:/ {
            if (cur == "") next
            line = $0
            sub(/^[[:space:]]*[0-9a-f]+:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*$/, "", line)
            # Mask RIP-relative displacements and immediates, sign included: a
            # `lea sym(%rip)` keeps the same meaning whether `sym` lands above or
            # below the instruction, so the displacement magnitude AND its sign
            # move with the layout, not with the code.
            gsub(/-?0x[0-9a-f]+/, "0xADDR", line)
            gsub(/[0-9a-f]+ </, "<", line)
            sub(/[[:space:]]+$/, "", line)
            # Drop inter-function alignment padding (int3 / nop family): the
            # linker lays each function on a 16-byte boundary, so the count of
            # padding bytes after a function shifts purely with its address, not
            # with the code. Counting it as code reads a relocation as a change.
            if (line ~ /^(int3|nop|nopl|nopw|nopq)([[:space:]]|$)/) next
            if (line ~ /^xchg[[:space:]]+%ax,%ax$/) next
            if (line ~ /^(cs|data16)[[:space:]].*nop/) next
            print cur "\t" line
        }'
}

# Distinct function names appearing in a `<function>\t<insn>` stream.
func_names() { cut -f1 "$1" | sort -u; }

# A stable view of a section's bytes (hex dump, offset column stripped).
sec_hex() { readelf -x "$2" "$1" 2>/dev/null | awk '{$1=""; print}'; }

# The dynamic interface: defined exports (type + name) and undefined imports.
dyn_def() { nm -D --defined-only "$1" 2>/dev/null | awk '{print $2, $3}' | sort; }
dyn_und() { nm -D -u "$1" 2>/dev/null | awk '{print $NF}' | sort; }

# DT_NEEDED set.
needed() { readelf -d "$1" 2>/dev/null | awk -F'[][]' '/\(NEEDED\)/{print $2}' | sort; }

# --- collect the differing ELFs present on both sides --------------------------
: >"$OUT/elf_both_differ"
while IFS= read -r f; do
    f=${f#./}
    [ -z "$f" ] && continue
    [ -f "$B/$f" ] || continue
    is_elf "$A/$f" || continue
    cmp -s "$A/$f" "$B/$f" && continue
    printf '%s\n' "$f" >>"$OUT/elf_both_differ"
done < <(cd "$A" && find . -type f 2>/dev/null | sort)

total=$(wc -l <"$OUT/elf_both_differ")
echo "differing ELFs present on both sides: $total"
echo

: >"$OUT/benign"
: >"$OUT/layout"
: >"$OUT/investigate"
: >"$OUT/overlink"
n=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    n=$((n + 1))
    printf '\r  classifying %s/%s ...\033[K' "$n" "$total" >&2

    reasons=""
    code="identical"

    # 1. code: compare the normalized per-function instruction streams. First as
    # emitted (address order); if that differs, again sorted by the whole
    # (name, body) record, so a pure link-order reshuffle of identical functions
    # reads as "layout", not as a code change. Sorting on the full record (rather
    # than the name key) keeps duplicate static-symbol names with distinct bodies
    # correctly paired when the linker emits them in opposite order.
    func_stream "$A/$f" >"$OUT/.fa"
    func_stream "$B/$f" >"$OUT/.fb"
    if ! cmp -s "$OUT/.fa" "$OUT/.fb"; then
        sort "$OUT/.fa" >"$OUT/.sa"
        sort "$OUT/.fb" >"$OUT/.sb"
        if cmp -s "$OUT/.sa" "$OUT/.sb"; then
            code="layout"
        else
            nf=$(diff "$OUT/.sa" "$OUT/.sb" | grep -E '^[<>]' | sed -E 's/^[<>] //' | cut -f1 | sort -u | grep -c .)
            setdiff=$(comm -3 <(func_names "$OUT/.fa") <(func_names "$OUT/.fb") | grep -c .)
            if [ "$setdiff" -gt 0 ]; then
                code="diff(${nf}_funcs,${setdiff}_set)"
            else
                code="diff(${nf}_funcs)"
            fi
            reasons="$reasons code_$code"
        fi
    fi

    # 2. compiler identity.
    cmp -s <(readelf -p .comment "$A/$f" 2>/dev/null) \
           <(readelf -p .comment "$B/$f" 2>/dev/null) \
        || reasons="$reasons comment_diff"

    # 3. dynamic interface (exports + imports).
    cmp -s <(dyn_def "$A/$f") <(dyn_def "$B/$f") || reasons="$reasons export_diff"
    cmp -s <(dyn_und "$A/$f") <(dyn_und "$B/$f") || reasons="$reasons import_diff"

    # over-link bookkeeping: DT_NEEDED the cc side adds that meson does not.
    extra=$(comm -13 <(needed "$A/$f") <(needed "$B/$f") | tr '\n' ',' | sed 's/,$//')
    [ -n "$extra" ] && printf '%s\t%s\n' "$f" "$extra" >>"$OUT/overlink"

    if [ -n "$reasons" ]; then
        printf '%s\treasons:%s\n' "$f" "$reasons" >>"$OUT/investigate"
    elif [ "$code" = "layout" ]; then
        printf '%s\n' "$f" >>"$OUT/layout"
    else
        printf '%s\n' "$f" >>"$OUT/benign"
    fi
done <"$OUT/elf_both_differ"
printf '\r\033[K' >&2

benign=$(wc -l <"$OUT/benign")
layout=$(wc -l <"$OUT/layout")
inv=$(wc -l <"$OUT/investigate")

echo "==================== VERDICT ===================="
printf 'BENIGN      (identical code, identical layout)  : %s\n' "$benign"
printf 'LAYOUT      (identical code, link order differs) : %s\n' "$layout"
printf 'INVESTIGATE (code / ABI / compiler differ)      : %s\n' "$inv"
echo
if [ -s "$OUT/layout" ]; then
    echo "--- LAYOUT (same per-function instructions, reordered by the linker) ---"
    sed 's/^/  /' "$OUT/layout"
    echo
fi
if [ -s "$OUT/investigate" ]; then
    echo "--- INVESTIGATE detail ---"
    sed 's/^/  /' "$OUT/investigate"
    echo
fi

# over-link summary: how many binaries add libs, and which libs most often.
if [ -s "$OUT/overlink" ]; then
    echo "--- over-link: cc binaries carrying DT_NEEDED meson omits ---"
    printf '  binaries with extra NEEDED: %s / %s\n' "$(wc -l <"$OUT/overlink")" "$total"
    echo "  most-added libraries (lib: count of binaries):"
    cut -f2 "$OUT/overlink" | tr ',' '\n' | sed '/^$/d' | sort | uniq -c | sort -rn \
        | head -25 | awk '{printf "    %5d  %s\n", $1, $2}'
fi

echo
echo "==================== DONE ===================="
echo "Artifacts in $OUT: elf_both_differ / benign / investigate / overlink"
