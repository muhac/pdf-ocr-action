#!/usr/bin/env bash
# End-to-end tests for scripts/ocr.sh. Runs real OCR, so macOS only.
# Usage: tests/run.sh   (set OCR_RECOGNITION to test a specific recognition mode)
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
ocr="$root/scripts/ocr.sh"
fixtures="$root/tests/fixtures"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

pass() { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

# Whitespace is stripped because OCR may put spaces between CJK characters.
text_of() { uvx --quiet --from pdfminer.six pdf2txt.py "$1" | tr -d '[:space:]'; }

assert_contains() { # <description> <pdf> <expected text without whitespace>
  if [ -f "$2" ] && text_of "$2" | grep -q -F "$3"; then pass "$1"; else fail "$1"; fi
}

assert_status() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected exit $2, got $3)"; fi
}

echo "# fixtures are image-only"
if [ -z "$(text_of "$fixtures/english.pdf")" ] && [ -z "$(text_of "$fixtures/chinese.pdf")" ]; then
  pass "fixtures contain no text before OCR"
else
  fail "fixtures contain no text before OCR"
fi

echo "# single file"
"$ocr" "$fixtures/english.pdf" "$work/single/english.pdf"
assert_status "single file exits 0" 0 $?
assert_contains "english text is recognized" "$work/single/english.pdf" "quickbrownfox"
assert_contains "digits are recognized" "$work/single/english.pdf" "20481"

echo "# directory, Chinese"
mkdir -p "$work/in"
cp "$fixtures/chinese.pdf" "$work/in/"
OCR_LANGUAGE=chi_sim "$ocr" "$work/in" "$work/out"
assert_status "directory exits 0" 0 $?
assert_contains "chinese text is recognized" "$work/out/chinese.pdf" "扫描版文档可以变成可搜索的文档"
assert_contains "english inside chinese page is recognized" "$work/out/chinese.pdf" "Englishwords"

echo "# pages that already have text"
"$ocr" "$work/single/english.pdf" "$work/again/english.pdf"
assert_status "skip mode accepts a PDF that already has text" 0 $?
assert_contains "existing text is kept" "$work/again/english.pdf" "quickbrownfox"
OCR_MODE=force "$ocr" "$work/single/english.pdf" "$work/forced/english.pdf"
assert_status "force mode exits 0" 0 $?
assert_contains "force mode produces text" "$work/forced/english.pdf" "quickbrownfox"

echo "# one bad file does not stop the others"
mkdir -p "$work/mixed"
cp "$fixtures/english.pdf" "$work/mixed/good.pdf"
echo "not a pdf" > "$work/mixed/broken.pdf"
"$ocr" "$work/mixed" "$work/mixed-out"
assert_status "directory with a bad file exits 1" 1 $?
assert_contains "good file is still processed" "$work/mixed-out/good.pdf" "quickbrownfox"
if [ ! -e "$work/mixed-out/broken.pdf" ]; then pass "bad file has no output"; else fail "bad file has no output"; fi

echo "# quiet mode hides file names"
mkdir -p "$work/secret"
cp "$fixtures/english.pdf" "$work/secret/confidential-name.pdf"
log=$(OCR_QUIET=true "$ocr" "$work/secret" "$work/secret-out" 2>&1)
assert_status "quiet mode exits 0" 0 $?
if echo "$log" | grep -q "confidential-name"; then fail "quiet log has no file names"; else pass "quiet log has no file names"; fi
assert_contains "quiet mode still produces output" "$work/secret-out/confidential-name.pdf" "quickbrownfox"

echo "# invalid options"
OCR_MODE=bogus "$ocr" "$fixtures/english.pdf" "$work/bogus.pdf" 2>/dev/null
assert_status "unknown mode exits 2" 2 $?
"$ocr" "$work/does-not-exist.pdf" "$work/none.pdf" 2>/dev/null
assert_status "missing input exits 2" 2 $?

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
