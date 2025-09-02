#!/usr/bin/env bash
# progress-bar.lib.sh — source this in your scripts
# Namespaced with pbar:: to avoid collisions.

# ---- Capabilities ------------------------------------------------------------
pbar::is_tty() { [[ -t 1 ]]; }
pbar::is_utf8() { [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]] || [[ "${LANG:-}" =~ UTF-8 ]]; }

# ---- Config / State ----------------------------------------------------------
# External knobs (env):
#   NO_COLOR=1         -> disable all colors
#   FORCE_ASCII=1      -> use ASCII bar characters
#   PBAR_SHOW_COUNTS=0 -> hide ok/fail tallies
: "${PBAR_SHOW_COUNTS:=1}"

# Internal state
PBAR_INIT=0
PBAR_TOTAL=0
PBAR_CUR=0
PBAR_START=0
PBAR_LAST_PCT=-1
PBAR_TERM_WIDTH=80
PBAR_OK=0
PBAR_FAIL=0
PBAR_SPIN_PID=
PBAR_HAVE_COLOR=0

# Colors (init lazily)
pbar::colors_init() {
  if pbar::is_tty; then
    PBAR_RED=$(tput setaf 1); PBAR_GREEN=$(tput setaf 2); PBAR_YELLOW=$(tput setaf 3)
    PBAR_BLUE=$(tput setaf 4); PBAR_DIM=$(tput dim); PBAR_BOLD=$(tput bold); PBAR_RESET=$(tput sgr0)
  else
    PBAR_RED= PBAR_GREEN= PBAR_YELLOW= PBAR_BLUE= PBAR_DIM= PBAR_BOLD= PBAR_RESET=
  fi
  [[ -n "${NO_COLOR:-}" ]] && PBAR_RED= PBAR_GREEN= PBAR_YELLOW= PBAR_BLUE= PBAR_DIM= PBAR_BOLD= PBAR_RESET=
  PBAR_HAVE_COLOR=0
  [[ -n "${PBAR_RESET:-}" ]] && PBAR_HAVE_COLOR=1
}

# Characters
pbar::chars_init() {
  if pbar::is_utf8 && [[ "${FORCE_ASCII:-0}" != 1 ]]; then
    PBAR_FULL="█"; PBAR_EMPTY="░"; PBAR_LBR="["; PBAR_RBR="]"
  else
    PBAR_FULL="#"; PBAR_EMPTY="."; PBAR_LBR="["; PBAR_RBR="]"
  fi
}

# Unicode-safe repeat
pbar::repeat() {
  local s=$1 n=$2 buf
  printf -v buf '%*s' "$n" ''
  printf '%s' "${buf// /$s}"
}

# Compute terminal width reliably (macOS/VS Code safe)
pbar::compute_width() {
  local cols=
  cols=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
  if [[ -z "$cols" || "$cols" -le 0 ]]; then
    if [[ -n "${COLUMNS:-}" && "$COLUMNS" -gt 0 ]]; then cols=$COLUMNS; fi
  fi
  if [[ -z "$cols" || "$cols" -le 0 ]]; then
    cols=$(tput cols 2>/dev/null)
  fi
  PBAR_TERM_WIDTH=${cols:-80}
}

# Cursor visibility
pbar::hide_cursor() { pbar::is_tty && tput civis; }
pbar::show_cursor() { pbar::is_tty && tput cnorm; }

# Cleanup
pbar::cleanup() { pbar::show_cursor; printf "\n"; }

# ---- Public API --------------------------------------------------------------

# pbar::init TOTAL
pbar::init() {
  [[ $PBAR_INIT -eq 1 ]] || {
    pbar::colors_init
    pbar::chars_init
    pbar::compute_width
    trap 'pbar::compute_width' SIGWINCH
    trap 'pbar::cleanup' EXIT INT TERM
    pbar::hide_cursor
    PBAR_INIT=1
  }
  PBAR_TOTAL=$1
  PBAR_CUR=0
  PBAR_OK=0
  PBAR_FAIL=0
  PBAR_START=$(date +%s)
  PBAR_LAST_PCT=-1
}

# pbar::ok [N]     — increment OK counter
pbar::ok()    { local n=${1:-1}; (( PBAR_OK+=n )); }
# pbar::fail [N]   — increment FAIL counter
pbar::fail()  { local n=${1:-1}; (( PBAR_FAIL+=n )); }

# pbar::set_total TOTAL  — allow updating total mid-run
pbar::set_total() { PBAR_TOTAL=$1; }

# pbar::advance DELTA [label] — advance current by DELTA
pbar::advance() {
  local delta=$1 label=${2:-}
  (( PBAR_CUR+=delta ))
  (( PBAR_CUR>PBAR_TOTAL )) && PBAR_CUR=$PBAR_TOTAL
  pbar::update "$PBAR_CUR" "$label"
}

# pbar::tick [label] — advance by 1
pbar::tick() { pbar::advance 1 "$1"; }

# pbar::update CURRENT [label]
pbar::update() {
  pbar::compute_width
  local cur=$1 label=${2:-}
  (( PBAR_TOTAL == 0 )) && return

  local pct=$(( cur * 100 / PBAR_TOTAL ))
  (( pct == PBAR_LAST_PCT )) && return
  PBAR_LAST_PCT=$pct

  local now elapsed rate remain eta
  now=$(date +%s)
  elapsed=$(( now - PBAR_START ))
  (( elapsed < 1 )) && elapsed=1
  rate=$(( cur / elapsed ))
  remain=$(( PBAR_TOTAL - cur ))
  eta=$(( rate > 0 ? remain / rate : 0 ))

  # hh:mm:ss format
  local fmt_hms
  fmt_hms() { local s=$1 h m; ((h=s/3600, m=(s%3600)/60, s=s%60)); printf "%02d:%02d:%02d" "$h" "$m" "$s"; }
  local elapsed_s eta_s
  elapsed_s=$(fmt_hms "$elapsed")
  eta_s=$(fmt_hms "$eta")

  # Build plain right side (no ANSI) for length math
  local right_plain
  if (( PBAR_SHOW_COUNTS )); then
    right_plain="$(printf "%s/%s | %3d%%%% | %s item/s | %s ETA %s | ok %s fail %s" \
                  "$cur" "$PBAR_TOTAL" "$pct" "$rate" "$elapsed_s" "$eta_s" "$PBAR_OK" "$PBAR_FAIL")"
  else
    right_plain="$(printf "%s/%s | %3d%%%% | %s item/s | %s ETA %s" \
                  "$cur" "$PBAR_TOTAL" "$pct" "$rate" "$elapsed_s" "$eta_s")"
  fi

  local usable=$(( PBAR_TERM_WIDTH - ${#right_plain} - 5 ))
  (( usable < 10 )) && usable=10

  local filled=$(( pct * usable / 100 ))
  local empty=$(( usable - filled ))
  local bar="$PBAR_LBR$(pbar::repeat "$PBAR_FULL" "$filled")$(pbar::repeat "$PBAR_EMPTY" "$empty")$PBAR_RBR"

  local max_label=$(( PBAR_TERM_WIDTH - ${#bar} - ${#right_plain} - 3 ))
  if (( max_label > 0 )) && [[ -n "$label" ]]; then
    if (( ${#label} > max_label )); then
      label="…${label: -$(( max_label-1 ))}"
    fi
    if (( PBAR_SHOW_COUNTS )); then
      printf "\r%s %s %s/%s | %3d%% | %s item/s | %s%s%s ETA %s | ok %s fail %s" \
        "${PBAR_GREEN}${bar}${PBAR_RESET}" "$label" \
        "$cur" "$PBAR_TOTAL" "$pct" "$rate" "$PBAR_DIM" "$elapsed_s" "$PBAR_RESET" "$eta_s" \
        "$PBAR_OK" "$PBAR_FAIL"
    else
      printf "\r%s %s %s/%s | %3d%% | %s item/s | %s%s%s ETA %s" \
        "${PBAR_GREEN}${bar}${PBAR_RESET}" "$label" \
        "$cur" "$PBAR_TOTAL" "$pct" "$rate" "$PBAR_DIM" "$elapsed_s" "$PBAR_RESET" "$eta_s"
    fi
  else
    if (( PBAR_SHOW_COUNTS )); then
      printf "\r%s %s/%s | %3d%% | %s item/s | %s%s%s ETA %s | ok %s fail %s" \
        "${PBAR_GREEN}${bar}${PBAR_RESET}" \
        "$cur" "$PBAR_TOTAL" "$pct" "$rate" "$PBAR_DIM" "$elapsed_s" "$PBAR_RESET" "$eta_s" \
        "$PBAR_OK" "$PBAR_FAIL"
    else
      printf "\r%s %s/%s | %3d%% | %s item/s | %s%s%s ETA %s" \
        "${PBAR_GREEN}${bar}${PBAR_RESET}" \
        "$cur" "$PBAR_TOTAL" "$pct" "$rate" "$PBAR_DIM" "$elapsed_s" "$PBAR_RESET" "$eta_s"
    fi
  fi
}

# pbar::finish
pbar::finish() {
  pbar::update "$PBAR_TOTAL"
  pbar::is_tty && printf "\n"
}

# Spinner
pbar::spinner_start() {
  local msg=${1:-"Working..."}
  local marks='-\|/' i=0

  # Ensure color vars exist even if init() hasn't run yet
  : "${PBAR_BOLD:=}"
  : "${PBAR_RESET:=}"

  (
    # Exit cleanly on TERM so the shell doesn’t print "Terminated: 15"
    trap 'exit 0' TERM
    while :; do
      printf "\r%s%s%s %s" "$PBAR_BOLD" "${marks:i:1}" "$PBAR_RESET" "$msg"
      i=$(( (i + 1) % 4 ))
      sleep 0.1
    done
  ) & PBAR_SPIN_PID=$!
}

pbar::spinner_stop() {
  if [[ -n "${PBAR_SPIN_PID:-}" ]]; then
    kill -TERM "$PBAR_SPIN_PID" 2>/dev/null || true
    # Consume the child's exit to suppress job messages
    wait "$PBAR_SPIN_PID" 2>/dev/null || true
  fi
  printf "\r\033[K"
  PBAR_SPIN_PID=
}

# Guard: do nothing if executed directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is a library. Source it from another script:"
  echo "  source ./progress-bar.lib.sh"
  exit 0
fi
