#!/usr/bin/env bash
# Shared helpers for key=value manifest files.

# manifest_read KEY FILE — print value for KEY, return 1 if absent
manifest_read() {
  grep "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2-
}

# manifest_set FILE KEY VALUE [KEY VALUE ...] — atomic upsert
manifest_set() {
  local file="$1"; shift
  local tmp="$file.tmp"
  local exclude=""
  local -a pairs=()

  while [ $# -ge 2 ]; do
    exclude="${exclude:+$exclude|}^$1="
    pairs+=("$1=$2")
    shift 2
  done

  { grep -Ev "$exclude" "$file" 2>/dev/null || true
    printf '%s\n' "${pairs[@]}"
  } > "$tmp"
  mv "$tmp" "$file"
}
