# Bash Progress Bar (modular)

A tiny, portable progress-bar **library** for Bash (macOS/Linux) plus a sample `worker.sh` you can adapt for your own batch jobs. The library handles the UI (width-aware bar, ETA, items/s, ok/fail tallies, spinner, colors); your script focuses on the actual work.

---

## Features

* Auto-width bar (resizes on the fly), Unicode or ASCII blocks, optional colors (`NO_COLOR`/`--no-color`).
* Elapsed/ETA, items/s, **ok/fail** counters.
* Works on macOS **Bash 3.2** and modern Linux Bash.
* Spinner for “discovery” phases.
* TTY-aware (pretty bar in terminals; simple lines when piped).

---

## Files

* `progress-bar.lib.sh` — the reusable library (namespaced `pbar::`).
* `worker.sh` — example script that shows how to **call the library** and where to put your work logic.

---

## Quick Start

```bash
# Make scripts executable
chmod +x progress-bar.lib.sh worker.sh

# Run the sample worker (processes files matching the default pattern)
./worker.sh

# Customize output file locations
./worker.sh --log ./logs/progress.log --failure ./logs/needs_attention.txt

# Or disable writing any files
./worker.sh --no-output
```

Sample output:

```
Finding Files…
Found 500 files
[██████████████████████████████████████████████████████████████████████] 500/500 | 100% | 22 item/s | 00:00:22 ETA 00:00:00 | ok 482 fail 18

❌ 18 item(s) failed. Saved to: ./failures.txt
```

---

## Using the Library in Your Own Script

### 1) Source the library

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/progress-bar.lib.sh"
```

### 2) Initialize with the total

```bash
total_files=${#files[@]}
pbar::init "$total_files"
```

### 3) Do your work and update the bar

Implement a function that processes **one item** and returns:

* `0` = success
* `10` = transient error (retryable)
* `non-zero` (e.g., `20`) = permanent error

```bash
process_item() {
  local path=$1
  # TODO: your real work here
  # return 0 on success
  # return 10 for retryable/transient
  # return 20 for permanent failure
}
```

Update the bar as you go:

```bash
if process_item "$f"; then
  pbar::ok 1
else
  pbar::fail 1
fi
pbar::advance 1 "${f##*/}"   # advance by 1 and show a short label
```

### 4) Finish

```bash
pbar::finish
```

#### Library API (most-used)

* `pbar::init TOTAL` — start the bar for TOTAL items.
* `pbar::advance DELTA [label]` — move forward by DELTA (use a label if you like).
* `pbar::tick [label]` — shorthand for `advance 1`.
* `pbar::ok [N]` / `pbar::fail [N]` — increment success/failure counters.
* `pbar::finish` — render final state and restore cursor.
* `pbar::spinner_start "message"` / `pbar::spinner_stop` — optional spinner for discovery.

Environment knobs:

* `NO_COLOR=1` (or `--no-color`) — disable colors.
* `FORCE_ASCII=1` (or `--ascii`) — use `#`/`.` instead of Unicode blocks.
* `PBAR_SHOW_COUNTS=0` — hide ok/fail tallies.

Portability notes:

* Width is detected via `/dev/tty` (macOS-safe).
* If `globstar` isn’t supported (macOS Bash 3.2), use `find` to gather files.

---

## Customizing the Sample Worker

`worker.sh` includes a simple CLI parser (Bash-3.2 friendly):

```
Usage: worker.sh [options]

File selection & batching:
  --pattern <glob>        File pattern to process (default: ./**/*cache)
  --batch-size <N>        Items per batch (default: 8)

Retries & failure behavior:
  --retries <N>           Retries for transient failures (exit 10) (default: 2)
  --retry-sleep <sec>     Seconds between retries (default: 0.2)
  --fail-fast             Stop immediately on first failure (default: off)

Logging & artifacts:
  --log <path>            Write progress log (TSV) (default: ./progress.log)
  --failure <path>        Write failed item paths (default: ./failures.txt)
  --no-output             Do not write any files (overrides --log/--failure)

Progress UI:
  --no-color              Disable ANSI color (also respects NO_COLOR env)
  --ascii                 Force ASCII bar characters (respects FORCE_ASCII=1)

Help:
  -h, --help              Show this help and exit
```

Examples:

```bash
./worker.sh --pattern './**/*.png' --batch-size 16 --retries 3 --retry-sleep 0.5
./worker.sh --fail-fast
./worker.sh --log ./logs/progress.log --failure ./logs/needs_attention.txt
./worker.sh --no-output
```

### Logs & Failures

* **Log file** (TSV): `ISO8601_UTC  status  path`
  e.g., `2025-09-02T16:10:45Z  ok    ./files/a.txt`
* **Failures file**: one path per line (easy to re-run just the failed items).

Exit codes:

* `0` — all items succeeded
* `1` — some items failed
* `non-zero item code` — if `--fail-fast` stopped early

---

## Troubleshooting

* **Bar stuck at 80 cols on macOS**
  The library reads width from `/dev/tty` each update and excludes ANSI from length math. If you still see 80, ensure you’re running in a TTY (not piped).

* **Weird “�” glyphs in Codespaces**
  Your terminal font may not support block glyphs. Set `FORCE_ASCII=1` or use a font with block elements.

* **Spinner prints “Terminated: 15”**
  The library traps and waits for the spinner process so stops are quiet. If you kill jobs elsewhere, do it the same way: `kill -TERM "$pid"; wait "$pid"`.

---

## Adapting to Your Project

Treat `worker.sh` as a template. Replace `process_item` with your real work, tweak the file discovery, and keep the progress UI by sourcing `progress-bar.lib.sh`. If you need parallelism or different batching semantics later, the library will still just count and draw, your worker stays in control.
