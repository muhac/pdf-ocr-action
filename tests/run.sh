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

echo "# language subfolders"
mkdir -p "$work/langs/chi_sim" "$work/langs/chi_tra" "$work/langs/notes"
cp "$fixtures/english.pdf" "$work/langs/english.pdf"
cp "$fixtures/chinese.pdf" "$work/langs/chi_sim/simplified.pdf"
cp "$fixtures/traditional.pdf" "$work/langs/chi_tra/traditional.pdf"
cp "$fixtures/english.pdf" "$work/langs/notes/ignored.pdf"
# accurate mode cannot read Chinese as English, so these only pass if the folder's language is used.
OCR_RECOGNITION=accurate "$ocr" "$work/langs" "$work/langs-out"
assert_status "folder with language subfolders exits 0" 0 $?
assert_contains "top-level file uses the default language" "$work/langs-out/english.pdf" "quickbrownfox"
assert_contains "chi_sim folder is read as Simplified Chinese" "$work/langs-out/chi_sim/simplified.pdf" "扫描版文档可以变成可搜索的文档"
assert_contains "chi_tra folder is read as Traditional Chinese" "$work/langs-out/chi_tra/traditional.pdf" "掃描版文件可以變成可搜尋的文件"
if [ ! -e "$work/langs-out/notes" ]; then pass "other subfolders are ignored"; else fail "other subfolders are ignored"; fi

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

echo "# storage with language subfolders"
seed_remote langs inbox
mkdir -p "$work/langs-seed/inbox/chi_sim" "$work/langs-seed/inbox/chi_tra" "$work/langs-seed/inbox/notes"
touch "$work/langs-seed/inbox/chi_sim/.gitkeep"
cp "$fixtures/chinese.pdf" "$work/langs-seed/inbox/chi_sim/private-zh.pdf"
echo "not a pdf" > "$work/langs-seed/inbox/chi_tra/private-bad.pdf"
cp "$fixtures/english.pdf" "$work/langs-seed/inbox/notes/private-note.pdf"
git -C "$work/langs-seed" add -A
git -C "$work/langs-seed" -c user.name=test -c user.email=test@example.com commit -q -m "more"
git -C "$work/langs-seed" push -q origin HEAD:main
export STORAGE_URL="$work/langs.git"
log=$("$storage" fetch "$work/job-langs" 2>&1)
log="$log$(OCR_QUIET=true "$ocr" "$work/job-langs/input" "$work/job-langs/output" 2>&1)"
log="$log$("$storage" save "$work/job-langs" 2>&1)"
assert_status "save with language subfolders exits 0" 0 $?
git clone -q "$work/langs.git" "$work/verify-langs"
assert_contains "top-level result is still pushed to done/" "$work/verify-langs/done/private-scan.pdf" "quickbrownfox"
assert_contains "language folder result keeps its folder" "$work/verify-langs/done/chi_sim/private-zh.pdf" "扫描版文档可以变成可搜索的文档"
if [ -f "$work/verify-langs/failed/chi_tra/private-bad.pdf" ]; then pass "language folder failure keeps its folder"; else fail "language folder failure keeps its folder"; fi
if [ -z "$(ls "$work/verify-langs/inbox/chi_sim")" ] && [ -f "$work/verify-langs/inbox/chi_sim/.gitkeep" ]; then pass "language folder is emptied but kept"; else fail "language folder is emptied but kept"; fi
if [ -f "$work/verify-langs/inbox/notes/private-note.pdf" ]; then pass "other inbox subfolders are left alone"; else fail "other inbox subfolders are left alone"; fi
if echo "$log" | grep -q -e "private-"; then fail "log has no file names with language subfolders"; else pass "log has no file names with language subfolders"; fi

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

echo "# only the working folders are downloaded"
git init -q --bare -b main "$work/big.git"
# What a hosting service allows; needed for a partial clone over file://.
git -C "$work/big.git" config uploadpack.allowFilter true
git -C "$work/big.git" config uploadpack.allowAnySHA1InWant true
git clone -q "$work/big.git" "$work/big-seed" 2>/dev/null
mkdir -p "$work/big-seed/inbox" "$work/big-seed/library/shelf"
cp "$fixtures/english.pdf" "$work/big-seed/inbox/private-scan.pdf"
cp "$fixtures/chinese.pdf" "$work/big-seed/library/shelf/private-archive.pdf"
echo "notes" > "$work/big-seed/README.md"
git -C "$work/big-seed" add -A
git -C "$work/big-seed" -c user.name=test -c user.email=test@example.com commit -q -m "seed"
git -C "$work/big-seed" push -q origin HEAD:main
archive=$(git -C "$work/big-seed" rev-parse "HEAD:library/shelf/private-archive.pdf")

export STORAGE_URL="file://$work/big.git"
"$storage" fetch "$work/job-big" >/dev/null 2>&1
assert_status "fetch over a partial clone exits 0" 0 $?
if [ -f "$work/job-big/input/private-scan.pdf" ]; then pass "inbox is checked out"; else fail "inbox is checked out"; fi
if [ ! -e "$work/job-big/repo/library" ]; then pass "other folders are not checked out"; else fail "other folders are not checked out"; fi
if git -C "$work/job-big/repo" rev-list --objects --missing=print HEAD 2>/dev/null | grep -q "^?$archive"; then pass "other folders are not downloaded"; else fail "other folders are not downloaded"; fi
OCR_QUIET=true "$ocr" "$work/job-big/input" "$work/job-big/output" >/dev/null 2>&1
"$storage" save "$work/job-big" >/dev/null 2>&1
assert_status "save from a partial clone exits 0" 0 $?
git clone -q "$work/big.git" "$work/verify-big"
assert_contains "result is pushed from a partial clone" "$work/verify-big/done/private-scan.pdf" "quickbrownfox"
if [ "$(git -C "$work/verify-big" rev-parse "HEAD:library/shelf/private-archive.pdf" 2>/dev/null)" = "$archive" ] && [ -f "$work/verify-big/README.md" ]; then pass "files outside the working folders are untouched"; else fail "files outside the working folders are untouched"; fi
unset STORAGE_URL

echo "# the user empties done/ while OCR is running"
git init -q --bare -b main "$work/busy.git"
git -C "$work/busy.git" config uploadpack.allowFilter true
git -C "$work/busy.git" config uploadpack.allowAnySHA1InWant true
git clone -q "$work/busy.git" "$work/busy-seed" 2>/dev/null
mkdir -p "$work/busy-seed/inbox" "$work/busy-seed/done"
cp "$fixtures/english.pdf" "$work/busy-seed/inbox/private-scan.pdf"
cp "$fixtures/chinese.pdf" "$work/busy-seed/done/private-earlier.pdf"
git -C "$work/busy-seed" add -A
git -C "$work/busy-seed" -c user.name=test -c user.email=test@example.com commit -q -m "seed"
git -C "$work/busy-seed" push -q origin HEAD:main
export STORAGE_URL="file://$work/busy.git"
"$storage" fetch "$work/job-busy" >/dev/null 2>&1
OCR_QUIET=true "$ocr" "$work/job-busy/input" "$work/job-busy/output" >/dev/null 2>&1
# Meanwhile the user files the only result out of done/, which git may read as a directory rename.
mkdir -p "$work/busy-seed/library"
git -C "$work/busy-seed" mv done/private-earlier.pdf library/private-earlier.pdf
git -C "$work/busy-seed" -c user.name=test -c user.email=test@example.com commit -q -m "file a book"
git -C "$work/busy-seed" push -q origin HEAD:main
"$storage" save "$work/job-busy" >/dev/null 2>&1
assert_status "save after the user emptied done/ exits 0" 0 $?
git clone -q "$work/busy.git" "$work/verify-busy"
assert_contains "result still lands in done/" "$work/verify-busy/done/private-scan.pdf" "quickbrownfox"
if [ -f "$work/verify-busy/library/private-earlier.pdf" ] && [ ! -e "$work/verify-busy/inbox/private-scan.pdf" ]; then pass "the user's move is kept and the inbox is emptied"; else fail "the user's move is kept and the inbox is emptied"; fi
unset STORAGE_URL

echo "# large files through releases"
git init -q --bare -b main "$work/rel.git"
git clone -q "$work/rel.git" "$work/rel-seed" 2>/dev/null
mkdir -p "$work/rel-seed/inbox"
touch "$work/rel-seed/inbox/.gitkeep"
git -C "$work/rel-seed" add -A
git -C "$work/rel-seed" -c user.name=test -c user.email=test@example.com commit -q -m "seed"
git -C "$work/rel-seed" push -q origin HEAD:main

export FAKE_GH_DIR="$work/fake-gh"
releases="$FAKE_GH_DIR/releases"
add_release() { # <tag> [description]
  mkdir -p "$releases/$1/assets"
  printf '%s' "${2:-}" > "$releases/$1/body"
}
add_release v-book1
cp "$fixtures/english.pdf" "$releases/v-book1/assets/default.pdf"
add_release v-book2 "chi_tra
more notes"
cp "$fixtures/traditional.pdf" "$releases/v-book2/assets/scan.pdf"
mkdir -p "$releases/v-book2/labels"
printf '繁體書.pdf' > "$releases/v-book2/labels/scan.pdf"
add_release v-bad
echo "not a pdf" > "$releases/v-bad/assets/broken.pdf"
add_release v-done
cp "$fixtures/english.pdf" "$releases/v-done/assets/old.pdf"
echo "done" > "$releases/v-done/assets/old.ocr.log"
add_release v-draft
touch "$releases/v-draft/draft"
cp "$fixtures/english.pdf" "$releases/v-draft/assets/draft.pdf"
add_release v-result
cp "$fixtures/english.pdf" "$releases/v-result/assets/only.ocr.pdf"

run_release_service() { # <workdir>: what the OCR workflow does, against the fake GitHub CLI
  (
    export PATH="$root/tests/fake-gh:$PATH" STORAGE_REPO=test/storage STORAGE_TOKEN=test-token
    export STORAGE_URL="$work/rel.git" OCR_LANGUAGE=eng OCR_RECOGNITION=accurate OCR_QUIET=true
    "$storage" fetch "$1" || exit
    "$ocr" "$1/input" "$1/output"
    [ -d "$1/release-input" ] && "$ocr" "$1/release-input" "$1/release-output"
    "$storage" save "$1"
  ) 2>&1
}
log=$(run_release_service "$work/job-rel")
assert_status "save with release files exits 0" 0 $?
assert_contains "result is attached to the release" "$releases/v-book1/assets/default.ocr.pdf" "quickbrownfox"
if [ "$(head -1 "$releases/v-book1/assets/default.ocr.log" 2>/dev/null)" = "done" ]; then pass "log says done"; else fail "log says done"; fi
if sed -n 2p "$releases/v-book1/assets/default.ocr.log" 2>/dev/null | grep -q "eng"; then pass "log records the default language"; else fail "log records the default language"; fi
# accurate mode cannot read Chinese as English, so this only passes if the description's language is used.
assert_contains "language in the release description is used" "$releases/v-book2/assets/scan.ocr.pdf" "掃描版文件可以變成可搜尋的文件"
if sed -n 2p "$releases/v-book2/assets/scan.ocr.log" 2>/dev/null | grep -q "chi_tra"; then pass "log records the release language"; else fail "log records the release language"; fi
if [ "$(cat "$releases/v-book2/labels/scan.ocr.pdf" 2>/dev/null)" = "繁體書.ocr.pdf" ]; then pass "result keeps the display label"; else fail "result keeps the display label"; fi
if [ "$(cat "$releases/v-book2/labels/scan.ocr.log" 2>/dev/null)" = "繁體書.ocr.log" ]; then pass "log keeps the display label"; else fail "log keeps the display label"; fi
if [ "$(head -1 "$releases/v-bad/assets/broken.ocr.log" 2>/dev/null)" = "failed" ] && [ ! -e "$releases/v-bad/assets/broken.ocr.pdf" ]; then pass "bad file gets a failed log and no result"; else fail "bad file gets a failed log and no result"; fi
if [ ! -e "$releases/v-done/assets/old.ocr.pdf" ]; then pass "file with a log is skipped"; else fail "file with a log is skipped"; fi
if [ "$(find "$releases/v-draft/assets" -type f | wc -l | tr -d ' ')" = 1 ]; then pass "draft release is skipped"; else fail "draft release is skipped"; fi
if [ "$(find "$releases/v-result/assets" -type f | wc -l | tr -d ' ')" = 1 ]; then pass "an .ocr.pdf is never treated as an original"; else fail "an .ocr.pdf is never treated as an original"; fi
if echo "$log" | grep -q -e "v-book" -e "v-bad" -e "default" -e "scan" -e "broken" -e "繁體" -e "test/storage"; then fail "log has no release or file names"; else pass "log has no release or file names"; fi

uploads=$(grep -c "release upload" "$FAKE_GH_DIR/calls.log")
run_release_service "$work/job-rel2" >/dev/null
assert_status "second run exits 0" 0 $?
if [ "$uploads" = "$(grep -c "release upload" "$FAKE_GH_DIR/calls.log")" ]; then pass "second run uploads nothing"; else fail "second run uploads nothing"; fi
unset FAKE_GH_DIR

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
