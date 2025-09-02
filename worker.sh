#!/usr/bin/env bash
set -uo pipefail

# Path to the progress bar library (adjust if needed)
source "$(dirname "${BASH_SOURCE[0]}")/progress-bar.lib.sh"

# ----------------- Defaults (can be overridden via flags or env) --------------
BATCH_SIZE=${BATCH_SIZE:-8}
PATTERN=${PATTERN:-'./**/*cache'}
RETRIES=${RETRIES:-2}
RETRY_SLEEP=${RETRY_SLEEP:-0.2}
FAIL_FAST=${FAIL_FAST:-0}

LOG=${LOG:-"./progress.log"}
FAIL_LIST=${FAIL_LIST:-"./failures.txt"}
NO_OUTPUT=${NO_OUTPUT:-0}

# ----------------- CLI parsing (portable, no GNU getopt) ----------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

File selection & batching:
  --pattern <glob>        File pattern to process
                          (default: ${PATTERN})
  --batch-size <N>        Items per batch
                          (default: ${BATCH_SIZE})

Retries & failure behavior:
  --retries <N>           Retries for transient failures (exit 10) (default: ${RETRIES})
  --retry-sleep <sec>     Seconds between retries                    (default: ${RETRY_SLEEP})
  --fail-fast             Stop immediately on first failure          (default: $( ((FAIL_FAST)) && echo "on" || echo "off" ))

Logging & artifacts:
  --log <path>            Write progress log (TSV) to this file      (default: ${LOG})
  --failure <path>        Write failed item paths to this file       (default: ${FAIL_LIST})
  --no-output             Do not write any files                     (overrides --log/--failure)

Progress UI:
  --no-color              Disable ANSI color                         (also respects NO_COLOR env)
  --ascii                 Force ASCII bar characters                 (respects FORCE_ASCII=1)

Help:
  -h, --help              Show this help message and exit

Examples:
  $(basename "$0") --log ./logs/progress.log --failure ./logs/needs_attention.txt
  $(basename "$0") --no-output
  BATCH_SIZE=16 PATTERN='./**/*.png' $(basename "$0")

Notes:
  • Exit codes: 0 on success, 1 if any item failed, or the failing item's code if --fail-fast.
  • Transient errors should return exit 10 from your process function; permanent errors return non-zero (e.g., 20).
  • You can also set env vars instead of flags: PATTERN, BATCH_SIZE, RETRIES, RETRY_SLEEP, FAIL_FAST, LOG, FAIL_LIST, NO_OUTPUT.
EOF
}


# Simple parser
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pattern)       PATTERN="$2"; shift 2 ;;
        --batch-size)    BATCH_SIZE="$2"; shift 2 ;;
        --retries)       RETRIES="$2"; shift 2 ;;
        --retry-sleep)   RETRY_SLEEP="$2"; shift 2 ;;
        --fail-fast)     FAIL_FAST=1; shift ;;
        --log)           LOG="$2"; shift 2 ;;
        --failure|--failures) FAIL_LIST="$2"; shift 2 ;;
        --no-output)     NO_OUTPUT=1; shift ;;
        --no-color)      export NO_COLOR=1; shift ;;
        --ascii)         export FORCE_ASCII=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        --)              shift; break ;;
        *)               echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

# ----------------- Helpers ----------------------------------------------------
iso8601_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
    # $1 = status tag, $2 = path
    (( NO_OUTPUT == 1 )) && return 0
    # Create directory once lazy on first write
    if [[ -n "${_LOG_INIT_DONE:-}" ]]; then :; else
        _LOG_INIT_DONE=1
        logdir="${LOG%/*}"; [[ "$logdir" != "$LOG" ]] && mkdir -p "$logdir" 2>/dev/null || true
    fi
    printf "%s\t%s\t%s\n" "$(iso8601_now)" "$1" "$2" >> "$LOG"
}

record_failure() {
    (( NO_OUTPUT == 1 )) && return 0
    if [[ -n "${_FAIL_INIT_DONE:-}" ]]; then :; else
        _FAIL_INIT_DONE=1
        faildir="${FAIL_LIST%/*}"; [[ "$faildir" != "$FAIL_LIST" ]] && mkdir -p "$faildir" 2>/dev/null || true
    fi
    printf "%s\n" "$1" >> "$FAIL_LIST"
}

# ----------------- Work functions --------------------------------------------
# Exit codes for process_item:
#   0  = success
#   10 = transient (retry)
#   20 = permanent (no retry)
process_item() {
    local f=$1
    # TODO: replace with real work
    sleep 0.03
    if (( RANDOM % 23 == 0 )); then return 10; fi
    if (( RANDOM % 31 == 0 )); then return 20; fi
    return 0
}

retry_transient() {
    local attempts=$1; shift
    local i rc
    for ((i=0; i<=attempts; i++)); do
        "$@"; rc=$?
        case $rc in
            0)  return 0 ;;
            10) sleep "$RETRY_SLEEP" ;;  # transient; retry
            *)  return $rc ;;             # permanent; stop
        esac
    done
    return 10
}

# ----------------- Discovery --------------------------------------------------
echo "Finding Files…"
pbar::spinner_start "Scanning ${PATTERN}"

if shopt -s globstar 2>/dev/null; then
    shopt -s nullglob 2>/dev/null || true
    files=($PATTERN)
else
    files=()
    while IFS= read -r -d '' f; do files+=("$f"); done < <(find . -type f -name "${PATTERN##*/}" -print0)
fi

pbar::spinner_stop

len=${#files[@]}
echo "Found $len files"
(( len == 0 )) && exit 0

# Prep output files (truncate) unless --no-output
if (( NO_OUTPUT == 0 )); then
    # ensure dirs exist; truncate files
    logdir="${LOG%/*}";     [[ "$logdir"    != "$LOG"       ]] && mkdir -p "$logdir" 2>/dev/null || true
    faildir="${FAIL_LIST%/*}"; [[ "$faildir" != "$FAIL_LIST" ]] && mkdir -p "$faildir" 2>/dev/null || true
    : > "$LOG"
    : > "$FAIL_LIST"
fi

# ----------------- Progress & loop -------------------------------------------
pbar::init "$len"

FAILED=()

for ((i=0; i<len; i+=BATCH_SIZE)); do
    local_end=$(( i + BATCH_SIZE )); (( local_end > len )) && local_end=$len
    
    for ((j=i; j<local_end; j++)); do
        f="${files[j]}"
        
        if retry_transient "$RETRIES" process_item "$f"; then
            pbar::ok 1
            log "ok" "$f"
        else
            rc=$?
            pbar::fail 1
            FAILED+=("$f|$rc")
            record_failure "$f"
            log "fail($rc)" "$f"
            if (( FAIL_FAST == 1 )); then
                pbar::advance 1 "${f##*/}"
                pbar::finish
                echo "Fail-fast: stopping on $f (exit $rc)"
                exit "$rc"
            fi
        fi
        
        pbar::advance 1 "${f##*/}"
    done
done

pbar::finish

# ----------------- Summary / exit code ---------------------------------------
if ((${#FAILED[@]})); then
    echo
    if (( NO_OUTPUT == 0 )); then
        echo "❌ ${#FAILED[@]} item(s) failed. Saved to: $FAIL_LIST"
    else
        echo "❌ ${#FAILED[@]} item(s) failed. (output disabled)"
    fi
    exit 1
else
    echo
    echo "✅ All ${len} item(s) completed successfully."
    exit 0
fi
