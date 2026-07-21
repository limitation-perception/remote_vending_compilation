#!/usr/bin/env bash
# Group B tests: SSH / real Raspberry Pi behavior.
#
# Split in two parts:
#   - AUTOMATED (below): read-only / non-destructive checks against the two
#     real boards in PIS[]. Safe to run anytime the boards are reachable —
#     nothing here scp's, builds, or deletes anything on them. If a board
#     is unreachable, those checks just FAIL/SKIP instead of hanging.
#   - MANUAL (printed at the end): scenarios that either modify real board
#     state (a real build, a real fetch) or require physically breaking
#     something (unplugging the board, killing sshd, editing known_hosts,
#     filling the disk) — these can't be scripted safely, so this prints
#     exact steps + expected outcome for you to run by hand.
#
# Nothing here needs a 3rd/spare Pi — build_pis.sh is hardcoded to exactly
# the two boards in PIS[], same as build_pis.sh itself.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build_pis.sh"

PASS=0
FAIL=0
SKIPPED_CHECKS=0

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

skip() {
  echo "SKIP: $1"
  SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
}

# Pull the real SSH option arrays / board list straight out of build_pis.sh
# instead of retyping IPs and flags here — same reasoning as
# test_group_a.sh's function extraction: these tests exercise the actual
# current script's connection settings, not a copy that can drift out of
# sync with it.
VARS=$(mktemp)
sed -n '/^CONTROL_DIR=/p' "$BUILD_SCRIPT" > "$VARS"
sed -n '/^SSH_OPTS=(/,/^)$/p' "$BUILD_SCRIPT" >> "$VARS"
sed -n '/^SSH_CMD_OPTS=/p' "$BUILD_SCRIPT" >> "$VARS"
sed -n '/^PIS=(/,/^)$/p' "$BUILD_SCRIPT" >> "$VARS"
sed -n '/^declare -A ARCH_DIR=(/,/^)$/p' "$BUILD_SCRIPT" >> "$VARS"
# shellcheck disable=SC1090
source "$VARS"
rm -f "$VARS"

mkdir -p "$CONTROL_DIR"
chmod 700 "$CONTROL_DIR"

echo "=== B1: board reachability + host-key policy (StrictHostKeyChecking=accept-new, ConnectTimeout=10) ==="
LIVE_PIS=()
for PI in "${PIS[@]}"; do
  if timeout 15 ssh "${SSH_CMD_OPTS[@]}" "$PI" true 2>/dev/null; then
    check "$PI reachable over ssh" "yes" "yes"
    LIVE_PIS+=("$PI")
  else
    check "$PI reachable over ssh" "no" "yes"
  fi
done

echo
echo "=== B3: control socket dir created with correct permissions ==="
check "CONTROL_DIR exists" "$([[ -d "$CONTROL_DIR" ]] && echo yes || echo no)" "yes"
check "CONTROL_DIR is 700" "$(stat -c%a "$CONTROL_DIR")" "700"

if [[ ${#LIVE_PIS[@]} -eq 0 ]]; then
  echo
  echo "Neither board is reachable right now — skipping B2/B4/B5 (need at least one live Pi)."
  skip "B2: control-socket multiplexing reuse"
  skip "B4: -n stdin isolation regression"
  skip "B5: remote ~/build read-only sanity check"
else
  PI="${LIVE_PIS[0]}"

  echo
  echo "=== B2: ControlMaster/ControlPath/ControlPersist actually reuse a connection ==="
  # %r@%h-%p expands to user@host-port; PIS entries are already user@host,
  # default port 22 — this must match ControlPath in SSH_OPTS above.
  SOCK="$CONTROL_DIR/${PI}-22"
  ssh "${SSH_CMD_OPTS[@]}" "$PI" true 2>/dev/null
  check "control socket file created after first connection" "$([[ -S "$SOCK" ]] && echo yes || echo no)" "yes"
  if [[ -S "$SOCK" ]]; then
    CHECK_OUT=$(ssh -O check -o ControlPath="$SOCK" "$PI" 2>&1)
    check "second ssh call sees master still running" "$([[ "$CHECK_OUT" == *"Master running"* ]] && echo yes || echo no)" "yes"
  fi

  echo
  echo "=== B4: SSH_CMD_OPTS' -n doesn't swallow the script's own piped stdin ==="
  # This is the exact regression the -n flag guards against: without it, a
  # plain `ssh host "cmd"` inherits this script's stdin, and when that
  # stdin is a pipe (as it is here), it can silently eat bytes meant for a
  # later `read -p` — the picker prompts would then see empty answers.
  RESULT=$(
    {
      ssh "${SSH_CMD_OPTS[@]}" "$PI" true 2>/dev/null
      read -r LINE
      echo "$LINE"
    } < <(printf 'expected-answer\n')
  )
  check "read after ssh call still gets the piped line" "$RESULT" "expected-answer"

  echo
  echo "=== B5: remote ~/build tar pull is read-only-safe and matches the board's real content ==="
  REMOTE_COPY=$(mktemp -d)
  ssh "${SSH_CMD_OPTS[@]}" "$PI" "mkdir -p ~/build && tar -cf - -C ~/build ." 2>/dev/null \
    | tar -xf - -C "$REMOTE_COPY" 2>/dev/null
  REMOTE_COUNT=$(ssh "${SSH_CMD_OPTS[@]}" "$PI" "find ~/build -type f | wc -l" 2>/dev/null)
  LOCAL_COUNT=$(find "$REMOTE_COPY" -type f | wc -l)
  check "pulled file count matches board's real ~/build" "$LOCAL_COUNT" "${REMOTE_COUNT:-__unset__}"
  rm -rf "$REMOTE_COPY"
fi

echo
echo "=== SUMMARY (automated): $PASS passed, $FAIL failed, $SKIPPED_CHECKS skipped ==="
echo
cat <<'MANUAL'
=======================================================================
MANUAL — run these by hand; each either changes real board state or
needs physically breaking something, so they're deliberately not
scripted. Run against the real two boards from PIS[] in build_pis.sh.
=======================================================================

B6. Full build pipeline, end to end, both architectures
    Run: ./build_pis.sh /path/to/a/real.zip  (with source that DID change
    on both boards, so neither takes the skip path).
    Check:
      - Both "=== pi@... STARTED ===" lines appear, both run concurrently
        (wall time roughly = the slower single build, not the sum).
      - build.log under result_bins/<arch>/ ends with "STATUS: OK" for
        each board that succeeded.
      - UNSTRIPPED_SIZE:<n> line is present in the log, but no unstripped
        binary file exists anywhere in result_bins/ or on the board
        afterwards (only the stripped one does).
      - versions.txt in each result_bins/<arch>/ gained a new
        "<hash> <version>" line, and the version matches what
        `ssh pi@... "cd ~/build && ./bar -v"` reports right after.
      - Summary table's ARCH column (via `file -b`) correctly reports
        "32 (armhf)" for x32_armhf and "64 (arm64)" for x64_arm64 —
        i.e. real board output, not a guess from the directory name.

B7. Skip path + "fetch anyway" against a real unchanged board
    Run the same zip again right after B6 (nothing changed now).
    Check:
      - Both boards print "no source changes — compilation will be
        skipped." and prompt "Fetch the latest binary from the board
        anyway? [y/N]".
      - Answering N: SKIP in the summary table, "(bin exists, skip)"
        note, no scp happens (check the timestamp on the local binary
        is untouched).
      - Answering Y on one board: local binary's mtime/sha updates, a new
        history/ entry is archived with the OLD version tag (not the new
        one), and versions.txt gets the freshly-queried version — even
        though no compilation happened.

B8. Parallel build isolation — one board fails, the other must not be
    affected
    Rig a zip whose bar.pro (or source) only fails to compile — e.g. a
    syntax error — but only stage it so ONE board sees changed source
    (or temporarily rename `qmake` on one Pi's PATH). Run the script.
    Check:
      - The healthy board still reaches "STATUS: OK" — the failing
        board's `make` error doesn't kill the `wait`-ed background job
        for the other one.
      - Failing board's build.log ends "STATUS: FAIL" and contains the
        real qmake/make error output.
      - Exit code: with exactly one board failing, `echo $?` after the
        run equals that board's 1-based position in PIS[] (1 for
        pi@10.0.0.58, 2 for pi@10.0.0.47) — not 10.
      - Revert whatever was broken, run once more with both boards
        healthy, confirm exit code 0 and both OK.

B9. Both boards fail -> exit 10
    Break both boards the same way as B8 (or point ZIP_PATH at a zip with
    broken source on both). Check `echo $?` == 10, and the summary table
    shows ✘ (red) with "(see log: ...)" for both rows.

B10. Real host-key change is rejected, not silently accepted
    StrictHostKeyChecking=accept-new only auto-trusts a HOST SEEN FOR THE
    FIRST TIME — it must still reject a key that CHANGED (e.g. after
    re-imaging a Pi's SD card). To check this without re-imaging:
      - Note the current line for one Pi in ~/.ssh/known_hosts.
      - Replace just that line with a bogus key of the same length/format.
      - Run build_pis.sh (or a bare `ssh` with the same SSH_OPTS) against
        that Pi.
    Expected: ssh refuses with a "REMOTE HOST IDENTIFICATION HAS CHANGED"
    warning and a non-zero exit — NOT a silent connect. That board should
    show up as FAIL in the summary, the other board unaffected.
    Afterwards: restore the original known_hosts line (or delete it and
    reconnect once to re-accept the real key).

B11. Unreachable board (powered off / network unplugged) doesn't hang
    Physically unplug one Pi's network (or power it off), then run
    build_pis.sh with a zip you know differs from that board's last
    build.
    Check:
      - The unreachable board's ssh/scp calls give up around
        ConnectTimeout=10s (time it — should be roughly 10s, not minutes).
      - It ends up FAIL in the summary; the other, reachable board still
        completes normally and independently.
      - Exit code reflects only the unreachable board failing (its
        position in PIS[]), same rule as B8.
    Reconnect the board afterwards and re-run once to confirm it's back
    to OK.

B12. SSH auth failure is handled like any other remote failure
    Temporarily point at a Pi user/key combo that will fail auth (e.g.
    a bad IdentityFile via -o, or temporarily chmod a private key to
    something sshd will refuse) for exactly one board.
    Check: same shape as B8/B11 — that board FAILs cleanly with the auth
    error visible in build.log, the other board is unaffected, exit code
    matches that board's position. Restore the key/permissions after.

B13. Disk full on the board mid-build
    Fill the board's disk close to capacity (e.g. `fallocate -l <N>G
    ~/fill_disk.img` for some Pi user with no room left for the build) on
    one Pi only, then run a build that requires compiling on it.
    Check: `make` fails as expected, build.log captures the real
    "No space left on device" (or similar) error, STATUS: FAIL is
    written, the other board is unaffected. Remove the fill file
    afterwards and re-run once to confirm recovery.
MANUAL

[[ "$FAIL" -eq 0 ]]
