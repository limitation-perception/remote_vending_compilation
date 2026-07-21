#!/usr/bin/env bash
# Group A tests: pure logic, no SSH, no real Raspberry Pis touched.
# Safe to run anywhere, any time.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build_pis.sh"

PASS=0
FAIL=0

check() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (got '$actual', expected '$expected')"
    FAIL=$((FAIL + 1))
  fi
}

# Pull the real function bodies and the real zip-picker block straight out
# of build_pis.sh instead of retyping them — these tests exercise the
# actual current script, not a copy that can drift out of sync with it.
FUNCS=$(mktemp)
sed -n '/^version_for_hash() {/,/^}/p' "$BUILD_SCRIPT" > "$FUNCS"
sed -n '/^record_version() {/,/^}/p' "$BUILD_SCRIPT" >> "$FUNCS"
sed -n '/^archive_old_binary() {/,/^}/p' "$BUILD_SCRIPT" >> "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

PICKER=$(mktemp)
sed -n '/^ZIP_PATH="\${1:-}"/,/^fi$/p' "$BUILD_SCRIPT" > "$PICKER"

echo "=== A9: syntax ==="
if bash -n "$BUILD_SCRIPT"; then
  check "bash -n syntax" "ok" "ok"
else
  check "bash -n syntax" "syntax error" "ok"
fi

echo
echo "=== A6: version regex ==="
OUT=$(echo "spritz, version 0.16, date Jul 21 2026 14:30:00 (c)" | grep -oP 'version \K[0-9]+(\.[0-9]+)*')
check "regex extracts 0.16" "$OUT" "0.16"
EMPTY=$(echo "no version word here" | grep -oP 'version \K[0-9]+(\.[0-9]+)*' || true)
check "regex empty on no match" "$EMPTY" ""

echo
echo "=== A4: version_for_hash / record_version ==="
TMPD=$(mktemp -d)
MAP="$TMPD/versions.txt"
echo "abc12345 0.16" > "$MAP"
check "known hash -> 0.16" "$(version_for_hash "$MAP" abc12345)" "0.16"
check "unknown hash -> unknown" "$(version_for_hash "$MAP" deadbeef)" "unknown"
check "empty hash -> unknown" "$(version_for_hash "$MAP" "")" "unknown"
check "missing map file -> unknown" "$(version_for_hash "$TMPD/nofile.txt" abc12345)" "unknown"

rm -f "$MAP"
record_version "$MAP" ffff0001 1.0
check "record_version: first entry" "$(wc -l < "$MAP")" "1"
record_version "$MAP" ffff0001 1.0
check "record_version: no duplicate" "$(wc -l < "$MAP")" "1"
record_version "$MAP" ffff0002 2.0
check "record_version: new hash appended" "$(wc -l < "$MAP")" "2"
rm -rf "$TMPD"

echo
echo "=== A5: archive_old_binary ==="
TMPD=$(mktemp -d)
HIST="$TMPD/history"
BIN="$TMPD/bar"
echo v1 > "$BIN"
touch -d '2026-07-21 11:38:15' "$BIN"
archive_old_binary "$BIN" "$HIST" "0.16"
check "archive: file created" "$(ls "$HIST" | wc -l)" "1"
echo v1-again > "$BIN"
touch -d '2026-07-21 11:38:15' "$BIN"
archive_old_binary "$BIN" "$HIST" "0.16"
check "archive: collision suffixed, not overwritten" "$(ls "$HIST" | wc -l)" "2"
rm -rf "$HIST"
archive_old_binary "$TMPD/nonexistent" "$HIST" "0.16"
check "archive: missing source -> no history dir" "$([[ -d "$HIST" ]] && echo yes || echo no)" "no"
rm -rf "$TMPD"

echo
echo "=== A7: exit code logic ==="
exit_code_for() {
  local count="$1" pos="$2"
  ( if [[ "$count" -eq 0 ]]; then exit 0; elif [[ "$count" -eq 1 ]]; then exit "$pos"; else exit 10; fi )
  echo $?
}
check "0 failed -> 0" "$(exit_code_for 0 0)" "0"
check "1 failed at pos 1 -> 1" "$(exit_code_for 1 1)" "1"
check "1 failed at pos 2 -> 2" "$(exit_code_for 1 2)" "2"
check "2 failed -> 10" "$(exit_code_for 2 0)" "10"
check "3 failed -> 10" "$(exit_code_for 3 0)" "10"

echo
echo "=== A8: diff artifact filtering ==="
DIR1=$(mktemp -d); DIR2=$(mktemp -d)
echo "int main(){}" > "$DIR1/main.cpp"
echo "int main(){}" > "$DIR2/main.cpp"
touch "$DIR2/main.o" "$DIR2/Makefile" "$DIR2/bar"
DIFF_OUT=$(diff -rq "$DIR1" "$DIR2" 2>&1 | grep -vF "Only in $DIR2")
check "build artifacts filtered out" "$([[ -z "$DIFF_OUT" ]] && echo empty || echo nonempty)" "empty"
echo "int main(){return 1;}" > "$DIR1/main.cpp"
DIFF_OUT=$(diff -rq "$DIR1" "$DIR2" 2>&1 | grep -vF "Only in $DIR2")
check "real source change detected" "$([[ -n "$DIFF_OUT" ]] && echo nonempty || echo empty)" "nonempty"
echo "extra" > "$DIR1/newfile.h"
DIFF_OUT=$(diff -rq "$DIR1" "$DIR2" 2>&1 | grep -vF "Only in $DIR2")
check "new zip-side file detected" "$(echo "$DIFF_OUT" | grep -q "Only in $DIR1" && echo yes || echo no)" "yes"
rm -rf "$DIR1" "$DIR2"

echo
echo "=== A1/A2/A3: zip picker ==="
run_picker() {
  local downloads_dir="$1" arg="${2:-}"
  bash -c '
DOWNLOADS_DIR="'"$downloads_dir"'"
ZIP_KEYWORDS=("bar" "sport")
'"$(cat "$PICKER")"'
echo "$ZIP_PATH"
' _ "$arg" 2>/dev/null
}

TMPD=$(mktemp -d); touch "$TMPD/other.zip"
R=$(printf '/manual/path.zip\n' | run_picker "$TMPD")
check "no matches -> manual entry" "$R" "/manual/path.zip"
rm -rf "$TMPD"

TMPD=$(mktemp -d); touch "$TMPD/bar_v1.zip"
R=$(printf '\n' | run_picker "$TMPD")
check "single match, Enter -> use it" "$R" "$TMPD/bar_v1.zip"
rm -rf "$TMPD"

TMPD=$(mktemp -d); touch "$TMPD/bar_v1.zip"
R=$(printf 'n\n/manual/fallback.zip\n' | run_picker "$TMPD")
check "single match, N -> manual fallback" "$R" "/manual/fallback.zip"
rm -rf "$TMPD"

TMPD=$(mktemp -d); touch "$TMPD/bar_v1.zip" "$TMPD/sport_v2.zip"
R=$(run_picker "$TMPD" "/explicit/arg.zip" < /dev/null)
check "explicit arg skips picker" "$R" "/explicit/arg.zip"
rm -rf "$TMPD"

TMPD=$(mktemp -d); touch "$TMPD/bar_v1.zip" "$TMPD/sport_v2.zip"
R=$(printf '2\n' | run_picker "$TMPD")
check "multi match, pick #2" "$R" "$TMPD/sport_v2.zip"
rm -rf "$TMPD"

TMPD=$(mktemp -d); touch "$TMPD/bar_v1.zip" "$TMPD/sport_v2.zip"
R=$(printf '0\n/typed/manually.zip\n' | run_picker "$TMPD")
check "multi match, 0 -> manual" "$R" "/typed/manually.zip"
rm -rf "$TMPD"

TMPD=$(mktemp -d); touch "$TMPD/bar_v1.zip" "$TMPD/sport_v2.zip"
R=$(printf '99\nabc\n\n1\n' | run_picker "$TMPD")
check "invalid inputs before valid choice" "$R" "$TMPD/bar_v1.zip"
rm -rf "$TMPD"

rm -f "$FUNCS" "$PICKER"

echo
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
