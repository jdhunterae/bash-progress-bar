#!/usr/bin/env bash

# This script processes files in batches and displays a dynamic progress bar
# that adjusts to the terminal's width.

BATCH_SIZE=1

progress-bar() {
  local index=$1
  local total=$2

  # Get the terminal width and subtract space for the text on the right
  local TERMINAL_WIDTH=$(tput cols)
  # We subtract a number large enough to hold all the text after the bar
  # including the brackets and the percentage. You can adjust this number.
  local width=$((TERMINAL_WIDTH - 20))

  # If the calculated width is too small or invalid, use a default value
  if [[ "$width" -le 0 ]]; then
      width=50
  fi

  local bar_char='|'
  local empty_char=' '
  local percent=$((index * 100 / total))
  local num_bars=$((percent * width / 100))

  local i
  local s='['
  for ((i = 0; i < num_bars; i++)); do
    s+=$bar_char
  done
  for ((i = num_bars; i < width; i++)); do
    s+=$empty_char
  done
  s+=']'

  # Use printf for better control and \r to overwrite the line
  printf "\r%s %s/%s (%s%%)" "$s" "$index" "$total" "$percent"
}

process-files() {
  local files=("$@")

  sleep .01
}

shopt -s globstar nullglob

echo 'finding files'
files=(./**/*cache)
len=${#files[@]}
echo "found $len files"

# The main loop now uses the updated progress-bar function
for ((i = 0; i < len; i += BATCH_SIZE)); do
  progress-bar "$((i+1))" "$len"
  process-files "${files[@]:i:BATCH_SIZE}"
done

# Display the final state of the bar
progress-bar "$len" "$len"

# Print a newline to clear the line for the next prompt
echo
