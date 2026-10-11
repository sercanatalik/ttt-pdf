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
[{"name":"pdf-viewer","version":"0.2.0","enabled":true,"permissions":{"editor.file_handlers":true,"keybindings":true,"events.file":true,"system.exec":["pdfinfo","pdftoppm","pdftotext"]}}]
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

run goto sample.pdf 'wait-for "Alpha page"; type :; wait-for "Go to page (1-3)"; type 3; key enter; wait-for "Charlie page"; type :; type -1; key enter; wait 150' && \
  expect goto "page 2/3" ": jumps to a page number and to a relative page" || fail "go to page"

run goto_bad sample.pdf 'wait-for "Alpha page"; type :; type 9; key enter; wait-for "No page 9"' && \
  expect goto_bad "page 1/3" ": rejects a page outside the document" || fail "go to page (out of range)"

printf '\x00\x01\x02not a pdf\xff' > "$FIXTURES/broken.pdf"
run broken broken.pdf 'wait-for "pdfinfo failed"' && \
  expect broken "pdfinfo failed" "a corrupt file shows the pdfinfo error" || fail "broken"
rm -f "$FIXTURES/broken.pdf"

mkdir -p "$WORK/empty-path"
run encrypted encrypted.pdf 'wait-for "password-protected"' && \
  expect encrypted "encrypted.pdf is password-protected" "an encrypted PDF explains why it can't open" || fail "encrypted"

run missing sample.pdf 'wait-for "is not available"' PATH="$WORK/empty-path" && \
  expect missing "Install poppler" "missing poppler shows install instructions" || fail "missing poppler"

# Image mode needs a terminal that reports pixel sizes; tests/kitty.py fakes one like Ghostty and decodes what ttt sends.
if command -v python3 >/dev/null; then
  GFX="$WORK/gfx"
  if python3 -I "$ROOT/tests/kitty.py" "$TTT_BIN" "$FIXTURES" "$CFG" sample.pdf 120x40 10x20 "$GFX" \
      "MARK page" 'wait-for "[fit page]"; wait 1200' \
      "MARK idle" 'wait 800' \
      "MARK width" 'click 70 20; key w; wait-for "fit width 0%"; wait 1200' \
      "MARK down" 'key pgdn; wait-for "fit width 78%"; key pgdn; wait-for "fit width 100%"; key pgdn; wait-for "page 2/3"; wait 1200' \
      "MARK up" 'key pgup; wait-for "page 1/3"; wait-for "fit width 100%"; wait 1200' \
      "MARK end" >"$WORK/gfx.log" 2>&1; then
    sends() { grep -c "^\[$1\] a=t" "$WORK/gfx.log" || true; }
    page_send=$(grep -m1 -E "^\[(start|page)\] a=t" "$WORK/gfx.log" || true)
    w=$(echo "$page_send" | sed -E 's/.* s=([0-9]+).*/\1/'); h=$(echo "$page_send" | sed -E 's/.* v=([0-9]+).*/\1/')
    if [ -n "$page_send" ] && [ $((h * 1000 / w)) -ge 1270 ] && [ $((h * 1000 / w)) -le 1320 ]; then pass "fit page sends one letter-shaped page"; else fail "fit page sends one letter-shaped page"; fi
    ! grep -q "^\[idle\] a=" "$WORK/gfx.log" && pass "an idle redraw sends nothing" || fail "an idle redraw sends nothing"
    slice=$(grep -m1 "^\[width\] a=t" "$WORK/gfx.log" || true)
    sw=$(echo "$slice" | sed -E 's/.* s=([0-9]+).*/\1/')
    if [ "$(sends width)" = 1 ] && [ "${sw:-0}" -ge 1100 ] && [ "${sw:-0}" -le 1180 ]; then pass "w sends one slice as wide as the tab"; else fail "w sends one slice as wide as the tab"; fi
    [ "$(sends down)" = 3 ] && pass "PgDn scrolls the page, then moves to the next one" || fail "PgDn scrolls the page, then moves to the next one"
    [ "$(sends up)" = 1 ] && pass "PgUp at the top returns to the bottom of the previous page" || fail "PgUp at the top returns to the bottom of the previous page"
  else
    fail "image mode session"
  fi
  [ "$failures" -gt 0 ] && sed 's/^/        | /' "$WORK/gfx.log" >&2

  # Page 1 is portrait, page 2 landscape, page 3 portrait rotated 90 degrees: each should be sent in its own shape.
  if python3 -I "$ROOT/tests/kitty.py" "$TTT_BIN" "$FIXTURES" "$CFG" mixed.pdf 120x40 10x20 "$WORK/mixed" \
      "MARK p1" 'wait-for "[fit page]"; wait-for "page 1/3"; wait 1500' \
      "MARK p2" 'click 70 20; key n; wait-for "page 2/3"; wait 1500' \
      "MARK p3" 'key n; wait-for "page 3/3"; wait 1500' \
      "MARK end" >"$WORK/mixed.log" 2>&1; then
    shape() {
      local line w h
      line=$(grep -E "^\[($1)\] a=t" "$WORK/mixed.log" | tail -1)
      w=$(echo "$line" | sed -E 's/.* s=([0-9]+).*/\1/'); h=$(echo "$line" | sed -E 's/.* v=([0-9]+).*/\1/')
      # The tab is 33 rows x 20 px = 660 px tall; a page rendered at its own size fills at least 85% of that.
      if [ -z "$line" ]; then echo none; elif [ "$h" -lt 560 ]; then echo "too-small(${w}x${h})"; elif [ "$w" -gt "$h" ]; then echo landscape; else echo portrait; fi
    }
    got="$(shape 'start|p1') $(shape p2) $(shape p3)"
    if [ "$got" = "portrait landscape landscape" ]; then
      pass "each page renders at its own size and rotation"
    else
      fail "each page renders at its own size and rotation (got: $got)"
      sed 's/^/        | /' "$WORK/mixed.log" >&2
    fi
  else
    fail "mixed page sizes session"
    sed 's/^/        | /' "$WORK/mixed.log" >&2
  fi

  LIVE="$WORK/live"
  mkdir -p "$LIVE"
  cp "$FIXTURES/sample.pdf" "$LIVE/doc.pdf"
  if python3 -I "$ROOT/tests/kitty.py" "$TTT_BIN" "$LIVE" "$CFG" doc.pdf 120x40 10x20 "$WORK/reload" \
      "MARK open" 'wait-for "[fit page]"; click 70 20; type G; wait-for "page 3/3"; wait 1000' \
      "SH head -c 400 '$FIXTURES/short.pdf' > doc.pdf.tmp && mv doc.pdf.tmp doc.pdf" \
      "MARK partial" "wait 2500; screenshot $WORK/reload-partial.txt" \
      "SH cp '$FIXTURES/short.pdf' doc.pdf.tmp && mv doc.pdf.tmp doc.pdf" \
      "MARK reloaded" "wait-for \"page 2/2\"; wait 1200; screenshot $WORK/reload-done.txt" \
      "MARK text" 'key t; wait-for "Echo page"' \
      "MARK end" >"$WORK/reload.log" 2>&1; then
    if grep -qF "page 3/3" "$WORK/reload-partial.txt" && ! grep -qiE "failed|error" "$WORK/reload-partial.txt"; then
      pass "a half-written file is ignored and the page stays up"
    else
      fail "a half-written file is ignored and the page stays up"
    fi
    if grep -qF "[fit page]" "$WORK/reload-done.txt" && grep -q "^\[reloaded\] a=t" "$WORK/reload.log"; then
      pass "a rebuilt PDF reloads by itself, keeping the fit mode and clamping the page"
    else
      fail "a rebuilt PDF reloads by itself, keeping the fit mode and clamping the page"
    fi
    pass "the reloaded file's text shows in text mode"
  else
    fail "auto-reload session"
    sed 's/^/        | /' "$WORK/reload.log" >&2
  fi
else
  echo "  skip  image mode (python3 not found)"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
