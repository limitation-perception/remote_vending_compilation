#!/usr/bin/env bash
set -uo pipefail

COLOR_RED=$'\e[31m'
COLOR_GREEN=$'\e[32m'
COLOR_YELLOW=$'\e[33m'
COLOR_PURPLE=$'\e[35m'
COLOR_RESET=$'\e[0m'

SCRIPT_VERSION="0.0.1"
echo "${COLOR_PURPLE}build_pis.sh version $SCRIPT_VERSION started${COLOR_RESET}"

DOWNLOADS_DIR="$HOME/Downloads"
ZIP_KEYWORDS=("bar" "sport")
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

# -n redirects ssh's own stdin from /dev/null. None of our remote
# commands need local stdin — without this, a plain `ssh ... "cmd"`
# inherits the script's stdin and, when that stdin is a pipe (piped
# answers, automation) rather than a live terminal, silently consumes
# bytes meant for a later `read -p` in this script, making prompts see
# an empty answer. scp doesn't take -n (and doesn't have this problem,
# since it isn't running an arbitrary remote shell command), so this is
# a separate array, only ever used for actual `ssh host "command"` calls.
SSH_CMD_OPTS=(-n "${SSH_OPTS[@]}")

# unzip is now needed locally too (we extract it to diff against the
# board), not just on the Pi — this machine didn't need it before.
command -v unzip >/dev/null || { echo "unzip not found locally — needed for the byte-for-byte check against the board."; exit 1; }

# A zip path can be passed as the first argument ("./build_pis.sh
# /path/to/some.zip") to skip the picker entirely. Otherwise, no zip is
# hardcoded — scan Downloads for zips whose name matches one of
# ZIP_KEYWORDS, let you pick by number (or confirm the single match),
# and always allow typing a path by hand instead.
ZIP_PATH="${1:-}"

if [[ -z "$ZIP_PATH" ]]; then
  CANDIDATES=()
  while IFS= read -r -d '' f; do
    CANDIDATES+=("$f")
  done < <(find "$DOWNLOADS_DIR" -maxdepth 1 -iname "*.zip" -print0 2>/dev/null | sort -z)

  MATCHES=()
  for f in "${CANDIDATES[@]}"; do
    base=$(basename "$f")
    for kw in "${ZIP_KEYWORDS[@]}"; do
      if [[ "${base,,}" == *"${kw,,}"* ]]; then
        MATCHES+=("$f")
        break
      fi
    done
  done

  if [[ ${#MATCHES[@]} -eq 1 ]]; then
    echo "Found one archive: ${COLOR_GREEN}$(basename "${MATCHES[0]}")${COLOR_RESET}"
    read -r -p "Use it? [Y/n] " ANSWER
    if [[ -z "$ANSWER" || "$ANSWER" =~ ^[Yy]$ ]]; then
      ZIP_PATH="${MATCHES[0]}"
    fi
  elif [[ ${#MATCHES[@]} -gt 1 ]]; then
    echo "Found multiple archives in $DOWNLOADS_DIR:"
    for i in "${!MATCHES[@]}"; do
      printf '  %d) %s%s%s\n' "$((i + 1))" "$COLOR_GREEN" "$(basename "${MATCHES[$i]}")" "$COLOR_RESET"
    done
    echo "  0) enter path manually"
    while true; do
      read -r -p "Pick a number: " CHOICE
      if [[ "$CHOICE" == "0" ]]; then
        break
      elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#MATCHES[@]} )); then
        ZIP_PATH="${MATCHES[$((CHOICE - 1))]}"
        break
      else
        echo "Invalid number, try again."
      fi
    done
  else
    echo "No archives matching keywords (${ZIP_KEYWORDS[*]}) found in $DOWNLOADS_DIR."
  fi

  if [[ -z "$ZIP_PATH" ]]; then
    read -r -p "Enter the zip path manually: " ZIP_PATH
  fi
fi

[[ -f "$ZIP_PATH" ]] || { echo "ZIP not found: $ZIP_PATH"; exit 1; }
ZIP_NAME=$(basename "$ZIP_PATH")

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

# The version is no longer tracked in a side file — it's appended as a
# plain-text marker directly onto the binary itself, right after strip
# (see the build loop below): "\n#VERSION:<version>#\n". grep -a reads
# it back without executing the binary, which matters because these are
# ARM binaries this (x86_64) machine can't run — and it means the
# version travels with the file itself instead of a lookup table that
# can drift out of sync with it. Falls back to "unknown" for binaries
# that predate this marker or were placed there by hand.
version_from_binary() {
  local f="$1" v
  v=$(grep -a -oP '#VERSION:\K[^#]*' "$f" 2>/dev/null | tail -n1)
  echo "${v:-unknown}"
}

# Archives the current binary into history/ tagged with the version
# read from it (via version_from_binary, see above) and ITS OWN mtime
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
  ssh "${SSH_CMD_OPTS[@]}" "$PI" "mkdir -p ~/build && tar -cf - -C ~/build ." 2>/dev/null \
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
    read -r -p "${COLOR_YELLOW}Fetch the latest binary from the board anyway? [y/N] ${COLOR_RESET}" ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      # the board's copy already carries its own #VERSION# marker if it
      # was ever built through this script (appended right after strip,
      # see below) — no need to re-run it remotely just to ask
      archive_old_binary "$DEST_DIR/$BIN_NAME" "$DEST_DIR/history" "$(version_from_binary "$DEST_DIR/$BIN_NAME")"
      if scp "${SSH_OPTS[@]}" "$PI:~/build/$BIN_NAME" "$DEST_DIR/"; then
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

    { ssh "${SSH_CMD_OPTS[@]}" "$PI" "mkdir -p ~/build" \
        && scp "${SSH_OPTS[@]}" "$ZIP_PATH" "$PI:~/build/" \
        && ssh "${SSH_CMD_OPTS[@]}" "$PI" "cd ~/build && unzip -o $ZIP_NAME && qmake bar.pro && make clean && make -j2 && echo UNSTRIPPED_SIZE:\$(stat -c%s $BIN_NAME) && strip $BIN_NAME" \
        && NEW_VER=$( { ssh "${SSH_CMD_OPTS[@]}" "$PI" "cd ~/build && ./$BIN_NAME -v" 2>/dev/null | grep -oP 'version \K[0-9]+(\.[0-9]+)*'; } || true ) \
        && NEW_VER="${NEW_VER:-unknown}" \
        && echo "NEW_VERSION: $NEW_VER" \
        && ssh "${SSH_CMD_OPTS[@]}" "$PI" "cd ~/build && printf '\\n#VERSION:%s#\\n' \"$NEW_VER\" >> $BIN_NAME" \
        && archive_old_binary "$DEST_DIR/$BIN_NAME" "$DEST_DIR/history" "$(version_from_binary "$DEST_DIR/$BIN_NAME")" \
        && scp "${SSH_OPTS[@]}" "$PI:~/build/$BIN_NAME" "$DEST_DIR/" ; } \
      > "$LOG" 2>&1 \
      && { echo "STATUS: OK" >> "$LOG"; echo "${COLOR_GREEN}OK: $PI${COLOR_RESET}"; } \
      || { echo "STATUS: FAIL" >> "$LOG"; echo "${COLOR_RED}FAIL: $PI (see $LOG)${COLOR_RESET}"; }
  ) &
done

wait

echo
echo "=== BUILD SUMMARY TABLE ==="
printf "%-3s %-14s %-12s %-10s %-12s %s\n" " " "DIR" "ARCH" "SIZE" "UNSTRIPPED" "SHA256"
printf '%s\n' "-----------------------------------------------------------------------------"

FAILED_COUNT=0
FAILED_POS=0

for IDX in "${!PIS[@]}"; do
  PI="${PIS[$IDX]}"
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

  if [[ "$STATUS" == "FAIL" ]]; then
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_POS=$((IDX + 1))
  fi

  if [[ "$STATUS" != "FAIL" && -f "$BIN_PATH" ]]; then
    MARK_CHAR="✔"
    COLOR="32"
    if [[ "$STATUS" == "SKIP" ]]; then
      NOTE=" ${COLOR_YELLOW}(bin exists, skip)${COLOR_RESET}"
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

# Exit code reflects real build failures only (SKIP/OK both count as
# "fine" — SKIP means nothing needed doing). 0 = all fine, 1/2/... =
# that Pi's position in PIS crashed alone, 10 = more than one did (with
# only 2 Pis today that's "both" — kept as ">1" rather than "== all" so
# a 3rd Pi later doesn't need this rewritten).
if [[ "$FAILED_COUNT" -eq 0 ]]; then
  exit 0
elif [[ "$FAILED_COUNT" -eq 1 ]]; then
  exit "$FAILED_POS"
else
  exit 10
fi
