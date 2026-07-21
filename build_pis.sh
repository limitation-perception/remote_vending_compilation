#!/usr/bin/env bash
set -uo pipefail

ZIP_PATH="$HOME/Downloads/bar_v0.16.zip"
ZIP_NAME=$(basename "$ZIP_PATH")
BIN_NAME="bar"
RESULT_DIR="$HOME/Downloads/result_bins"
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

# Archives the current binary into history/ tagged with ITS OWN mtime
# (when that build was actually produced), before a fresh scp overwrites
# it. Previously only one past version was kept (${BIN_NAME}.prev,
# overwritten every time) — now history accumulates without limit: every
# successful build leaves its own trace in history/ and nothing is lost.
# A name collision (two versions sharing the same mtime second) is
# resolved with a counter suffix instead of silently overwriting.
archive_old_binary() {
  local f="$1" hist_dir="$2"
  [[ -f "$f" ]] || return 0
  mkdir -p "$hist_dir"
  local base ts dest n=1
  base=$(basename "$f")
  ts=$(date -d "@$(stat -c%Y "$f")" +%Y%m%d_%H%M%S)
  dest="$hist_dir/${base}.${ts}"
  while [[ -e "$dest" ]]; do
    dest="$hist_dir/${base}.${ts}_$((n++))"
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
    echo "$PI (${ARCH_DIR[$PI]}): board content is byte-for-byte identical to the zip — no point rebuilding."
    read -r -p "Fetch the existing binary again anyway? [y/N] " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      echo "$PI: using the existing binary $DEST_DIR/$BIN_NAME (no rebuild, no SSH/SCP)."
    else
      echo "$PI: skipping."
    fi
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

    { ssh "${SSH_OPTS[@]}" "$PI" "mkdir -p ~/build" \
        && scp "${SSH_OPTS[@]}" "$ZIP_PATH" "$PI:~/build/" \
        && ssh "${SSH_OPTS[@]}" "$PI" "cd ~/build && unzip -o $ZIP_NAME && qmake bar.pro && make clean && make -j2 && cp $BIN_NAME ${BIN_NAME}_not_stripped && strip $BIN_NAME" \
        && { archive_old_binary "$DEST_DIR/$BIN_NAME" "$DEST_DIR/history"; \
             archive_old_binary "$DEST_DIR/${BIN_NAME}_not_stripped" "$DEST_DIR/history"; \
             true; } \
        && scp "${SSH_OPTS[@]}" "$PI:~/build/$BIN_NAME" "$DEST_DIR/" \
        && scp "${SSH_OPTS[@]}" "$PI:~/build/${BIN_NAME}_not_stripped" "$DEST_DIR/" ; } \
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

  # the OK/FAIL marker is the last line the build block appended to
  # its own build.log — no separate status file anymore
  LAST_LINE=$(tail -n 1 "$DEST_DIR/build.log" 2>/dev/null)
  if [[ "$LAST_LINE" == "STATUS: OK" ]]; then
    STATUS="OK"
  else
    STATUS="FAIL"
  fi

  if [[ "$STATUS" == "OK" && -f "$BIN_PATH" ]]; then
    MARK_CHAR="✔"
    COLOR="32"
    # byte-exact size via stat+numfmt, not `du -h` — du reports
    # disk-block usage (rounds up to 4K), which is meaningless noise
    # next to a few KB of stripped debug symbols.
    # $BIN_NAME is the stripped, deployable binary (strip runs on the
    # Pi itself — a local x86_64 `strip` can't parse an ARM binary).
    SIZE=$(numfmt --to=iec --suffix=B "$(stat -c%s "$BIN_PATH")")
    SHA=$(sha256sum "$BIN_PATH" | cut -d' ' -f1 | cut -c1-8)

    NOT_STRIPPED_PATH="$DEST_DIR/${BIN_NAME}_not_stripped"
    if [[ -f "$NOT_STRIPPED_PATH" ]]; then
      NOT_STRIPPED_SIZE=$(numfmt --to=iec --suffix=B "$(stat -c%s "$NOT_STRIPPED_PATH")")
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
  fi

  # pad the row as plain text first, then colorize only the mark —
  # doing it the other way round breaks alignment because printf counts
  # the invisible ANSI escape bytes as part of the column width.
  printf -v ROW "%-3s %-14s %-12s %-10s %-12s %s" "$MARK_CHAR" "$DIRNAME" "$ARCH" "$SIZE" "$NOT_STRIPPED_SIZE" "$SHA"
  COLOR_MARK=$'\e['"$COLOR"'m'"$MARK_CHAR"$'\e[0m'
  ROW="${ROW/$MARK_CHAR/$COLOR_MARK}"
  printf '%s\n' "$ROW"
done
