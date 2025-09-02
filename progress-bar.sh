#!/usr/bin/env bash
set -uo pipefail

BATCH_SIZE=${BATCH_SIZE:-1}
PATTERN=${PATTERN:-'./**/*cache'}

# Try to enable globstar if this Bash supports it; always enable nullglob if present.
if shopt -s globstar 2>/dev/null; then
  shopt -s nullglob 2>/dev/null || true
  HAVE_GLOBSTAR=1
else
  shopt -s nullglob 2>/dev/null || true
  HAVE_GLOBSTAR=0
fi

# --- Capabilities ------------------------------------------------------------
is_tty() { [[ -t 1 ]]; }
is_utf8() { [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]] || [[ "${LANG:-}" =~ UTF-8 ]]; }

# COLORS (ONLY IF TTY; honor NO_COLOR)
if is_tty; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4); DIM=$(tput dim); BOLD=$(tput bold); RESET=$(tput sgr0)
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; DIM=""; BOLD=""; RESET=""
fi
# Respect NO_COLOR convention: https://no-color.org/
if [[ -n "${NO_COLOR:-}" ]]; then RED=""; GREEN=""; YELLOW=""; BLUE=""; DIM=""; BOLD=""; RESET=""; fi

# CHARACTERS
if is_utf8 && [[ "${FORCE_ASCII:-0}" != 1 ]]; then
  BAR_FULL="█"; BAR_EMPTY="░"; LBR="["; RBR="]"
else
  BAR_FULL="#"; BAR_EMPTY="."; LBR="["; RBR="]"
fi

# Unicode-safe repeat: repeat "█" 7 -> ███████
repeat() {
  local s=$1 n=$2 buf
  printf -v buf '%*s' "$n" ''
  printf '%s' "${buf// /$s}"
}

# --- Terminal width tracking -------------------------------------------------
TERM_WIDTH=80
compute_width() {
  local cols=
  cols=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
  if [[ -z "$cols" || "$cols" -le 0 ]]; then
    if [[ -n "${COLUMNS:-}" && "$COLUMNS" -gt 0 ]]; then cols=$COLUMNS; fi
  fi
  if [[ -z "$cols" || "$cols" -le 0 ]]; then
    cols=$(tput cols 2>/dev/null)
  fi
  TERM_WIDTH=${cols:-80}
}
compute_width
trap 'compute_width' SIGWINCH

# --- Cursor handling ---------------------------------------------------------
hide_cursor() { is_tty && tput civis; }
show_cursor() { is_tty && tput cnorm; }
cleanup() { show_cursor; printf "\n"; }
trap cleanup EXIT INT TERM

# --- Time helpers ------------------------------------------------------------
now_s() { date +%s; }
fmt_hms() {
  local s=$1 h m
  ((h=s/3600, m=(s%3600)/60, s=s%60))
  printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

# --- Progress bar core -------------------------------------------------------
OK_COUNT=0
ERR_COUNT=0

progress_setup() {
  PROG_TOTAL=$1
  PROG_START=$(now_s)
  PROG_LAST_PCT=-1
  is_tty && hide_cursor
}

progress_update() {
  compute_width
  local cur=$1 label=${2:-}
  (( PROG_TOTAL == 0 )) && return

  local pct=$(( cur * 100 / PROG_TOTAL ))
  (( pct == PROG_LAST_PCT )) && return
  PROG_LAST_PCT=$pct

  local elapsed=$(( $(now_s) - PROG_START ))
  (( elapsed < 1 )) && elapsed=1
  local rate=$(( cur / elapsed ))
  local remain=$(( PROG_TOTAL - cur ))
  local eta=$(( rate > 0 ? remain / rate : 0 ))

  local elapsed_s eta_s
  elapsed_s=$(fmt_hms "$elapsed")
  eta_s=$(fmt_hms "$eta")

  # Right side (plain) includes ok/fail tallies
  local right_plain
  right_plain="$(printf "%s/%s | %3d%%%% | %s items/s | %s ETA %s | ok %s fail %s" \
                  "$cur" "$PROG_TOTAL" "$pct" "$rate" "$elapsed_s" "$eta_s" "$OK_COUNT" "$ERR_COUNT")"

  local usable=$(( TERM_WIDTH - ${#right_plain} - 5 ))
  (( usable < 10 )) && usable=10

  local filled=$(( pct * usable / 100 ))
  local empty=$(( usable - filled ))

  local bar="$LBR$(repeat "$BAR_FULL" "$filled")$(repeat "$BAR_EMPTY" "$empty")$RBR"

  local max_label=$(( TERM_WIDTH - ${#bar} - ${#right_plain} - 3 ))
  if (( max_label > 0 )) && [[ -n "$label" ]]; then
    if (( ${#label} > max_label )); then
      label="...${label: -$(( max_label-3 ))}"
    fi
    printf "\r%s %s %s/%s | %3d%% | %s items/s | %s%s%s ETA %s | ok %s fail %s" \
      "${GREEN}${bar}${RESET}" "$label" \
      "$cur" "$PROG_TOTAL" "$pct" "$rate" "$DIM" "$elapsed_s" "$RESET" "$eta_s" \
      "$OK_COUNT" "$ERR_COUNT"
  else
    printf "\r%s %s/%s | %3d%% | %s items/s | %s%s%s ETA %s | ok %s fail %s" \
      "${GREEN}${bar}${RESET}" \
      "$cur" "$PROG_TOTAL" "$pct" "$rate" "$DIM" "$elapsed_s" "$RESET" "$eta_s" \
      "$OK_COUNT" "$ERR_COUNT"
  fi
}

progress_finish() {
  progress_update "$PROG_TOTAL"
  is_tty && printf "\n"
}

# --- Discovery Spinner -------------------------------------------------------
spinner() {
  local marks='-\|/' i=0 msg=${1:-"Working..."}
  while :; do
    # brighter mark, normal msg
    printf "\r%s%s%s %s" "$BOLD" "${marks:i:1}" "$RESET" "$msg"
    i=$(( (i + 1) % 4 ))
    sleep 0.1
  done
}

# --- Batch Work : EXAMPLE ----------------------------------------------------
# Return 0 for success, non-zero for failure
process_files() {
  local files=("$@")
  # simulate work
  sleep 0.01
  return 0
}

# --- Gather files (portable) -------------------------------------------------
echo "Finding Files..."
if is_tty; then
  spinner "Scanning ${PATTERN}" & SPIN_PID=$!
  # Optional: force the spinner to be visible for a bit (default 0 = no delay)
  SPINNER_MIN_SEC=${SPINNER_MIN_SEC:-0}
  if [[ "$SPINNER_MIN_SEC" != "0" && "$SPINNER_MIN_SEC" != "0.0" ]]; then
    sleep "$SPINNER_MIN_SEC"
  fi
fi

files=()
if (( HAVE_GLOBSTAR == 1 )); then
  files=($PATTERN)
else
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find . -type f -name "${PATTERN##*/}" -print0)
fi

# stop spinner
if [[ -n "${SPIN_PID:-}" ]]; then kill "$SPIN_PID" 2>/dev/null || true; fi
printf "\r\033[K"

len=${#files[@]}
echo "Found $len files"
(( len == 0 )) && { echo "${YELLOW}No files matched pattern.${RESET}"; exit 0; }

progress_setup "$len"

if is_tty; then
  for ((i=0; i < len; i += BATCH_SIZE)); do
    # determine batch window and progress count correctly for batching
    local_end=$(( i + BATCH_SIZE ))
    (( local_end > len )) && local_end=$len
    batch_size=$(( local_end - i ))
    current="${files[i]}"

    if process_files "${files[@]:i:batch_size}"; then
      (( OK_COUNT += batch_size ))
    else
      (( ERR_COUNT += batch_size ))
    fi

    cur_count=$local_end  # progress should reflect items attempted so far
    progress_update "$cur_count" "${current##*/}"
  done
  progress_finish
else
  # Non-TTY fallback: simple log lines (good for CI)
  for ((i=0; i< len; i+=BATCH_SIZE)); do
    local_end=$(( i + BATCH_SIZE ))
    (( local_end > len )) && local_end=$len
    batch_size=$(( local_end - i ))
    printf "%d/%d: %s\n" "$local_end" "$len" "${files[i]}"
    if process_files "${files[@]:i:batch_size}"; then
      (( OK_COUNT += batch_size ))
    else
      (( ERR_COUNT += batch_size ))
    fi
  done
  printf "Done: ok %s, fail %s\n" "$OK_COUNT" "$ERR_COUNT"
fi
