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

[[ -f "$ZIP_PATH" ]] || { echo "ZIP не знайдено: $ZIP_PATH"; exit 1; }

mkdir -p "$RESULT_DIR"
mkdir -p "$CONTROL_DIR"
chmod 700 "$CONTROL_DIR"

PIS=(
  "pi@10.0.0.58"
  "pi@10.0.0.47"
)

# архітектура прив'язана до конкретної малинки (залежить від того, яка
# ОС стоїть на її SD-картці), а не визначається щоразу заново — тож ім'я
# директорії кодує розрядність+архітектуру, а не IP
declare -A ARCH_DIR=(
  ["pi@10.0.0.58"]="x32_armhf"
  ["pi@10.0.0.47"]="x64_arm64"
)

ZIP_MTIME=$(stat -c%Y "$ZIP_PATH")

TO_BUILD=()

for PI in "${PIS[@]}"; do
  DEST_DIR="$RESULT_DIR/${ARCH_DIR[$PI]}"
  mkdir -p "$DEST_DIR"

  LAST_MTIME=$(cat "$DEST_DIR/last_src_mtime" 2>/dev/null || echo 0)

  if [[ -f "$DEST_DIR/$BIN_NAME" && "$ZIP_MTIME" -le "$LAST_MTIME" ]]; then
    echo "$PI (${ARCH_DIR[$PI]}): вихідники не змінювались з часу останньої вдалої збірки — компілювати нема сенсу."
    read -r -p "Отримати вже наявний бінарник ще раз? [y/N] " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      echo "$PI: використовую вже наявний бінарник $DEST_DIR/$BIN_NAME (без перекомпіляції, без SSH/SCP)."
    else
      echo "$PI: пропускаю."
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
        && { [[ -f "$DEST_DIR/$BIN_NAME" ]] && cp "$DEST_DIR/$BIN_NAME" "$DEST_DIR/${BIN_NAME}.prev"; \
             [[ -f "$DEST_DIR/${BIN_NAME}_not_stripped" ]] && cp "$DEST_DIR/${BIN_NAME}_not_stripped" "$DEST_DIR/${BIN_NAME}_not_stripped.prev"; \
             true; } \
        && scp "${SSH_OPTS[@]}" "$PI:~/build/$BIN_NAME" "$DEST_DIR/" \
        && scp "${SSH_OPTS[@]}" "$PI:~/build/${BIN_NAME}_not_stripped" "$DEST_DIR/" ; } \
      > "$LOG" 2>&1 \
      && { echo "STATUS: OK" >> "$LOG"; echo "OK: $PI"; echo "$ZIP_MTIME" > "$DEST_DIR/last_src_mtime"; } \
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
