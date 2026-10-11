#!/usr/bin/env bash
# Drives a real ttt binary headlessly against the plugin with its manifest permissions.
# Usage: TTT_BIN=/path/to/ttt tests/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TTT_BIN="${TTT_BIN:-ttt}"
FIXTURES="$ROOT/tests/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v "$TTT_BIN" >/dev/null || { echo "ttt binary not found: set TTT_BIN" >&2; exit 2; }
command -v pdftotext >/dev/null || { echo "poppler is required to run the tests" >&2; exit 2; }

CFG="$WORK/config"
mkdir -p "$CFG/plugins/pdf-viewer"
cp "$ROOT/plugin.ttt.json" "$ROOT/init.lua" "$CFG/plugins/pdf-viewer/"
cat > "$CFG/plugins.ttt.json" <<'JSON'
[{"name":"pdf-viewer","version":"0.1.0","enabled":true,"permissions":{"editor.file_handlers":true,"system.exec":["pdfinfo","pdftoppm","pdftotext"]}}]
JSON

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# run NAME FILE SCRIPT [env...]: runs ttt on FILE inside the fixtures dir; the screen is left in $WORK/NAME.txt.
run() {
  local name="$1" file="$2" script="$3"
  shift 3
  local out="$WORK/$name.txt"
  if (cd "$FIXTURES" && env "$@" TTT_CONFIG_DIR="$CFG" "$TTT_BIN" --size 110x14 "$file" \
      --exec "$script; screenshot $out; quit" >"$WORK/$name.log" 2>&1); then
    return 0
  fi
  cat "$WORK/$name.log" >&2
  return 1
}

expect() {
  local name="$1" text="$2" label="$3"
  if grep -qF -- "$text" "$WORK/$name.txt"; then pass "$label"; else fail "$label"; sed 's/^/        | /' "$WORK/$name.txt" >&2; fi
}

echo "pdf-viewer tests ($("$TTT_BIN" --version 2>/dev/null || echo "$TTT_BIN"))"

run open sample.pdf 'wait-for "Alpha page"' && {
  expect open "page 1/3" "opens from the command line on page 1"
  expect open "[text]" "falls back to text without graphics"
} || fail "open"

run paging sample.pdf 'wait-for "Alpha page"; key n; wait-for "Bravo page"; type G; wait-for "Charlie page"; key n; wait 150' && \
  expect paging "page 3/3" "n and G move forward and stop at the last page" || fail "paging"

run back sample.pdf 'wait-for "Alpha page"; type G; wait-for "Charlie page"; key g; wait-for "Alpha page"; key p; wait 150' && \
  expect back "page 1/3" "g and p move back and stop at the first page" || fail "back"

run reload sample.pdf 'wait-for "Alpha page"; key n; wait-for "Bravo page"; key r; wait-for "page 2/3"; wait-for "Bravo page"' && \
  expect reload "Bravo page" "r reloads and keeps the current page" || fail "reload"

printf '\x00\x01\x02not a pdf\xff' > "$FIXTURES/broken.pdf"
run broken broken.pdf 'wait-for "pdfinfo failed"' && \
  expect broken "pdfinfo failed" "a corrupt file shows the pdfinfo error" || fail "broken"
rm -f "$FIXTURES/broken.pdf"

run missing sample.pdf 'wait-for "is not available"' PATH=/usr/bin:/bin && \
  expect missing "Install poppler" "missing poppler shows install instructions" || fail "missing poppler"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
