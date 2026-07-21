#!/usr/bin/env bash
set -uo pipefail

SCRIPT_VERSION="0.0.1"
echo "build_pis.sh version $SCRIPT_VERSION started"

ZIP_PATH="$HOME/Downloads/bar_v0.16.zip"
ZIP_NAME=$(basename "$ZIP_PATH")
BIN_NAME="bar"
RESULT_DIR="$HOME/remote_vending_compilation/result_bins"
CONTROL_DIR="$HOME/.ssh/sockets"

SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=10
  -o ControlMaster=auto
  -o ControlPath="$CONTROL_DIR/%r@%h-%p"
  -o ControlPersist=60
)

[[ -f "$ZIP_PATH" ]] || { echo "ZIP not found: $ZIP_PATH"; exit 1; }
# unzip is now needed locally too (we extract it to diff against the
# board), not just on the Pi — this machine didn't need it before.
command -v unzip >/dev/null || { echo "unzip not found locally — needed for the byte-for-byte check against the board."; exit 1; }

mkdir -p "$RESULT_DIR"
mkdir -p "$CONTROL_DIR"
chmod 700 "$CONTROL_DIR"

PIS=(
  "pi@10.0.0.58"
  "pi@10.0.0.47"
)

# architecture is tied to the specific Pi (depends on which OS is on its
# SD card), not re-detected every run — so the directory name encodes
# bitness+architecture, not the IP
declare -A ARCH_DIR=(
  ["pi@10.0.0.58"]="x32_armhf"
  ["pi@10.0.0.47"]="x64_arm64"
)

# Each $DEST_DIR (one per architecture) keeps its own versions.txt,
# tying a binary's own sha256 (first 8 hex chars) to the version it was
# built from — one line per hash, "<hash> <version>". Kept per-arch (not
# one shared file) since armhf and arm64 binaries never share a hash
# anyway, and it keeps each board's history self-contained.
#
# Looks up the version recorded for a binary's hash in the given map
# file. Falls back to "unknown" if this exact binary was never recorded
# there (e.g. it predates the map, or was placed there by hand).
version_for_hash() {
  local map="$1" hash="$2" line
  [[ -n "$hash" ]] || { echo "unknown"; return; }
  line=$(grep "^${hash} " "$map" 2>/dev/null | tail -n1)
  if [[ -n "$line" ]]; then
    echo "${line#* }"
  else
    echo "unknown"
  fi
}

# Records a hash -> version pair in the given map file, the first time
# that exact hash is seen there; a later build producing byte-identical
# output won't duplicate the line.
record_version() {
  local map="$1" hash="$2" version="$3"
  touch "$map"
  grep -q "^${hash} " "$map" 2>/dev/null || echo "$hash $version" >> "$map"
}

# Archives the current binary into history/ tagged with the version
# looked up for it (via version_for_hash, see above) and ITS OWN mtime
# (when that build was actually produced), before a fresh scp overwrites
# it. Previously only one past version was kept (${BIN_NAME}.prev,
# overwritten every time) — now history accumulates without limit: every
# successful build leaves its own trace in history/ and nothing is lost.
# A name collision (two versions sharing the same mtime second) is
# resolved with a counter suffix instead of silently overwriting.
archive_old_binary() {
  local f="$1" hist_dir="$2" version="$3"
  [[ -f "$f" ]] || return 0
  mkdir -p "$hist_dir"
  local base ts dest n=1
  base=$(basename "$f")
  ts=$(date -d "@$(stat -c%Y "$f")" +%Y%m%d_%H%M%S)
  dest="$hist_dir/${base}_${version}__${ts}"
  while [[ -e "$dest" ]]; do
    dest="$hist_dir/${base}_${version}__${ts}_$((n++))"
  done
  cp "$f" "$dest"
}

# Extract the zip locally once — this is the source of truth for the
# diff. We compare actual file content against what's in ~/build on the
# board, not the zip's timestamp (it could be touched without content
# changing, or stay the same while content did change).
LOCAL_EXTRACT=$(mktemp -d)
trap 'rm -rf "$LOCAL_EXTRACT"' EXIT
unzip -q -o "$ZIP_PATH" -d "$LOCAL_EXTRACT"

TO_BUILD=()
SKIPPED=()

for PI in "${PIS[@]}"; do
  DEST_DIR="$RESULT_DIR/${ARCH_DIR[$PI]}"
  mkdir -p "$DEST_DIR"

  # Pull the current contents of ~/build from the board in one stream
  # (tar over ssh, no rsync) into a fresh temp dir, then diff it against
  # the local zip extraction with plain diff -rq — diff compares actual
  # file content, not size or mtime, so this is the byte-for-byte check.
  REMOTE_COPY=$(mktemp -d)
  ssh "${SSH_OPTS[@]}" "$PI" "mkdir -p ~/build && tar -cf - -C ~/build ." 2>/dev/null \
    | tar -xf - -C "$REMOTE_COPY" 2>/dev/null

  # "Only in $REMOTE_COPY: ..." means a file exists on the board but not
  # in the zip — that's a leftover build byproduct (Makefile, *.o, the
  # binary itself), not source. If we counted those as differences, the
  # "nothing changed" check would never trigger, since these files are
  # always left behind by the previous build. So those lines are
  # deliberately filtered out via grep -vF; we only keep "Files ...
  # differ" (a changed file) and "Only in $LOCAL_EXTRACT: ..." (a new
  # file not yet on the board) — i.e. real differences coming from the
  # zip's side.
  DIFF_OUT=$(diff -rq "$LOCAL_EXTRACT" "$REMOTE_COPY" 2>&1 | grep -vF "Only in $REMOTE_COPY")
  rm -rf "$REMOTE_COPY"

  if [[ -f "$DEST_DIR/$BIN_NAME" && -z "$DIFF_OUT" ]]; then
    echo "$PI (${ARCH_DIR[$PI]}): no source changes — compilation will be skipped."
    read -r -p "Fetch the latest binary from the board anyway? [y/N] " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      VERSIONS_MAP="$DEST_DIR/versions.txt"
      OLD_SHA=$(sha256sum "$DEST_DIR/$BIN_NAME" 2>/dev/null | cut -c1-8)
      archive_old_binary "$DEST_DIR/$BIN_NAME" "$DEST_DIR/history" "$(version_for_hash "$VERSIONS_MAP" "$OLD_SHA")"
      if scp "${SSH_OPTS[@]}" "$PI:~/build/$BIN_NAME" "$DEST_DIR/"; then
        # re-asked from the board's own binary rather than assumed
        # unchanged — cheap, and doesn't rely on nothing else having
        # touched ~/build between runs
        NEW_VER=$(ssh "${SSH_OPTS[@]}" "$PI" "cd ~/build && ./$BIN_NAME -v" 2>/dev/null | grep -oP 'version \K[0-9]+(\.[0-9]+)*')
        [[ -n "$NEW_VER" ]] || NEW_VER="unknown"
        NEW_SHA=$(sha256sum "$DEST_DIR/$BIN_NAME" | cut -c1-8)
        record_version "$VERSIONS_MAP" "$NEW_SHA" "$NEW_VER"
        echo "$PI: fetched the current binary from the board."
      else
        echo "$PI: failed to fetch the binary from the board."
      fi
    else
      echo "$PI: skipping."
    fi
    SKIPPED+=("$PI")
    continue
  fi

  TO_BUILD+=("$PI")
done

for PI in "${TO_BUILD[@]}"; do
  (
    echo "=== $PI: STARTED  ==="

    DEST_DIR="$RESULT_DIR/${ARCH_DIR[$PI]}"
    mkdir -p "$DEST_DIR"

    LOG="$DEST_DIR/build.log"
    VERSIONS_MAP="$DEST_DIR/versions.txt"

    { ssh "${SSH_OPTS[@]}" "$PI" "mkdir -p ~/build" \
        && scp "${SSH_OPTS[@]}" "$ZIP_PATH" "$PI:~/build/" \
        && ssh "${SSH_OPTS[@]}" "$PI" "cd ~/build && unzip -o $ZIP_NAME && qmake bar.pro && make clean && make -j2 && echo UNSTRIPPED_SIZE:\$(stat -c%s $BIN_NAME) && strip $BIN_NAME" \
        && NEW_VER=$( { ssh "${SSH_OPTS[@]}" "$PI" "cd ~/build && ./$BIN_NAME -v" 2>/dev/null | grep -oP 'version \K[0-9]+(\.[0-9]+)*'; } || true ) \
        && NEW_VER="${NEW_VER:-unknown}" \
        && echo "NEW_VERSION: $NEW_VER" \
        && OLD_SHA=$( { sha256sum "$DEST_DIR/$BIN_NAME" 2>/dev/null | cut -c1-8; } || true ) \
        && archive_old_binary "$DEST_DIR/$BIN_NAME" "$DEST_DIR/history" "$(version_for_hash "$VERSIONS_MAP" "$OLD_SHA")" \
        && scp "${SSH_OPTS[@]}" "$PI:~/build/$BIN_NAME" "$DEST_DIR/" \
        && NEW_SHA=$(sha256sum "$DEST_DIR/$BIN_NAME" | cut -c1-8) \
        && record_version "$VERSIONS_MAP" "$NEW_SHA" "$NEW_VER" ; } \
      > "$LOG" 2>&1 \
      && { echo "STATUS: OK" >> "$LOG"; echo "OK: $PI"; } \
      || { echo "STATUS: FAIL" >> "$LOG"; echo "FAIL: $PI (see $LOG)"; }
  ) &
done

wait

echo
echo "=== BUILD SUMMARY TABLE ==="
printf "%-3s %-14s %-12s %-10s %-12s %s\n" " " "DIR" "ARCH" "SIZE" "UNSTRIPPED" "SHA256"
printf '%s\n' "-----------------------------------------------------------------------------"

for PI in "${PIS[@]}"; do
  DIRNAME="${ARCH_DIR[$PI]}"
  DEST_DIR="$RESULT_DIR/$DIRNAME"
  BIN_PATH="$DEST_DIR/$BIN_NAME"

  # SKIP is decided up front (this PI never entered TO_BUILD this run) —
  # only PIs that actually attempted a build fall back to build.log's
  # last line for OK/FAIL, so a skip never gets read as a stale FAIL/OK
  # from a previous run's log.
  IS_SKIPPED=0
  for S in "${SKIPPED[@]}"; do
    [[ "$S" == "$PI" ]] && IS_SKIPPED=1 && break
  done

  if [[ "$IS_SKIPPED" == 1 ]]; then
    STATUS="SKIP"
  else
    # the OK/FAIL marker is the last line the build block appended to
    # its own build.log — no separate status file anymore
    LAST_LINE=$(tail -n 1 "$DEST_DIR/build.log" 2>/dev/null)
    if [[ "$LAST_LINE" == "STATUS: OK" ]]; then
      STATUS="OK"
    else
      STATUS="FAIL"
    fi
  fi

  if [[ "$STATUS" != "FAIL" && -f "$BIN_PATH" ]]; then
    MARK_CHAR="✔"
    COLOR="32"
    if [[ "$STATUS" == "SKIP" ]]; then
      NOTE=" (bin exists, skip)"
    else
      NOTE=""
    fi
    # byte-exact size via stat+numfmt, not `du -h` — du reports
    # disk-block usage (rounds up to 4K), which is meaningless noise
    # next to a few KB of stripped debug symbols.
    # $BIN_NAME is the stripped, deployable binary (strip runs on the
    # Pi itself — a local x86_64 `strip` can't parse an ARM binary).
    SIZE=$(numfmt --to=iec --suffix=B "$(stat -c%s "$BIN_PATH")")
    SHA=$(sha256sum "$BIN_PATH" | cut -d' ' -f1 | cut -c1-8)

    # the unstripped binary is never written to disk (not on the board,
    # not here) — its size is captured as a stat run remotely right
    # before `strip`, and lives only as a line in build.log
    UNSTRIPPED_RAW=$(grep -o 'UNSTRIPPED_SIZE:[0-9]*' "$DEST_DIR/build.log" 2>/dev/null | tail -n1 | cut -d: -f2)
    if [[ -n "$UNSTRIPPED_RAW" ]]; then
      NOT_STRIPPED_SIZE=$(numfmt --to=iec --suffix=B "$UNSTRIPPED_RAW")
    else
      NOT_STRIPPED_SIZE="-"
    fi

    FILEINFO=$(file -b "$BIN_PATH")
    if [[ "$FILEINFO" == *aarch64* ]]; then
      ARCH_NAME="arm64"
    elif [[ "$FILEINFO" == *ARM* ]]; then
      ARCH_NAME="armhf"
    else
      ARCH_NAME="?"
    fi

    if [[ "$FILEINFO" == *64-bit* ]]; then
      BITS="64"
    elif [[ "$FILEINFO" == *32-bit* ]]; then
      BITS="32"
    else
      BITS="?"
    fi

    ARCH="$BITS ($ARCH_NAME)"
  else
    MARK_CHAR="✘"
    COLOR="31"
    ARCH="-"
    SIZE="-"
    NOT_STRIPPED_SIZE="-"
    SHA="(see log: $DEST_DIR/build.log)"
    NOTE=""
  fi

  # pad the row as plain text first, then colorize only the mark —
  # doing it the other way round breaks alignment because printf counts
  # the invisible ANSI escape bytes as part of the column width.
  printf -v ROW "%-3s %-14s %-12s %-10s %-12s %s%s" "$MARK_CHAR" "$DIRNAME" "$ARCH" "$SIZE" "$NOT_STRIPPED_SIZE" "$SHA" "$NOTE"
  COLOR_MARK=$'\e['"$COLOR"'m'"$MARK_CHAR"$'\e[0m'
  ROW="${ROW/$MARK_CHAR/$COLOR_MARK}"
  printf '%s\n' "$ROW"
done
