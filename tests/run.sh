#!/usr/bin/env bash
# End-to-end tests for scripts/ocr.sh. Runs real OCR, so macOS only.
# Usage: tests/run.sh   (set OCR_RECOGNITION to test a specific recognition mode)
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
ocr="$root/scripts/ocr.sh"
storage="$root/scripts/storage.sh"
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

seed_remote() { # <name> <inbox dir>: a storage repository with one good and one bad PDF waiting
  git init -q --bare -b main "$work/$1.git"
  git clone -q "$work/$1.git" "$work/$1-seed" 2>/dev/null
  mkdir -p "$work/$1-seed/$2"
  touch "$work/$1-seed/$2/.gitkeep"
  cp "$fixtures/english.pdf" "$work/$1-seed/$2/private-scan.pdf"
  echo "not a pdf" > "$work/$1-seed/$2/private-broken.pdf"
  git -C "$work/$1-seed" add -A
  git -C "$work/$1-seed" -c user.name=test -c user.email=test@example.com commit -q -m "seed"
  git -C "$work/$1-seed" push -q origin HEAD:main
}

echo "# storage round trip"
seed_remote remote inbox

(unset STORAGE_REPO STORAGE_TOKEN STORAGE_URL; "$storage" fetch "$work/unconfigured" 2>/dev/null)
assert_status "fetch without configuration exits 2" 2 $?

export STORAGE_URL="$work/remote.git"
log=$("$storage" fetch "$work/job" 2>&1)
assert_status "fetch exits 0" 0 $?

log="$log$("$storage" save "$work/job" 2>&1)"
assert_status "save without results exits 0" 0 $?
if [ -f "$work/job/input/private-scan.pdf" ]; then pass "inbox is untouched when OCR did not run"; else fail "inbox is untouched when OCR did not run"; fi

log="$log$(OCR_QUIET=true "$ocr" "$work/job/input" "$work/job/output" 2>&1)"
log="$log$("$storage" save "$work/job" 2>&1)"
assert_status "save exits 0" 0 $?

git clone -q "$work/remote.git" "$work/verify"
assert_contains "result is pushed to done/" "$work/verify/done/private-scan.pdf" "quickbrownfox"
if [ -f "$work/verify/failed/private-broken.pdf" ]; then pass "bad file is moved to failed/"; else fail "bad file is moved to failed/"; fi
if [ -z "$(ls "$work/verify/inbox")" ] && [ -f "$work/verify/inbox/.gitkeep" ]; then pass "inbox is emptied but kept"; else fail "inbox is emptied but kept"; fi
if git -C "$work/verify" log -1 --format=%s | grep -q -F "[skip ci]"; then pass "commit skips CI"; else fail "commit skips CI"; fi
if echo "$log" | grep -q -e "private-" -e "remote.git"; then fail "service log has no file or repository names"; else pass "service log has no file or repository names"; fi

before=$(git -C "$work/verify" rev-parse HEAD)
"$storage" fetch "$work/job2" >/dev/null 2>&1
OCR_QUIET=true "$ocr" "$work/job2/input" "$work/job2/output" >/dev/null 2>&1
"$storage" save "$work/job2" >/dev/null 2>&1
assert_status "save with an empty inbox exits 0" 0 $?
git -C "$work/verify" pull -q
if [ "$before" = "$(git -C "$work/verify" rev-parse HEAD)" ]; then pass "empty inbox creates no commit"; else fail "empty inbox creates no commit"; fi

echo "# custom folders"
seed_remote custom "scans/to do"
export STORAGE_URL="$work/custom.git"
export STORAGE_INBOX="scans/to do" STORAGE_DONE="scans/finished" STORAGE_FAILED="problems"
log=$("$storage" fetch "$work/job3" 2>&1)
log="$log$(OCR_QUIET=true "$ocr" "$work/job3/input" "$work/job3/output" 2>&1)"
log="$log$("$storage" save "$work/job3" 2>&1)"
assert_status "save with custom folders exits 0" 0 $?
git clone -q "$work/custom.git" "$work/verify-custom"
assert_contains "result is pushed to the custom done folder" "$work/verify-custom/scans/finished/private-scan.pdf" "quickbrownfox"
if [ -f "$work/verify-custom/problems/private-broken.pdf" ]; then pass "bad file is moved to the custom failed folder"; else fail "bad file is moved to the custom failed folder"; fi
if [ -z "$(ls "$work/verify-custom/scans/to do")" ]; then pass "custom inbox is emptied"; else fail "custom inbox is emptied"; fi
if [ ! -e "$work/verify-custom/done" ] && [ ! -e "$work/verify-custom/failed" ] && [ ! -e "$work/verify-custom/inbox" ]; then pass "default folders are not created"; else fail "default folders are not created"; fi
if echo "$log" | grep -q -e "scans" -e "finished" -e "problems"; then fail "service log has no folder names"; else pass "service log has no folder names"; fi

STORAGE_INBOX="../outside" "$storage" fetch "$work/job4" 2>/dev/null
assert_status "folder outside the repository exits 2" 2 $?
STORAGE_DONE="scans/to do" "$storage" fetch "$work/job5" 2>/dev/null
assert_status "inbox and done being the same folder exits 2" 2 $?
unset STORAGE_URL STORAGE_INBOX STORAGE_DONE STORAGE_FAILED

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
