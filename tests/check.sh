#!/usr/bin/env bash
# Tests for scripts/check.py. No OCR involved, so they run on Linux as well as macOS.
# Usage: tests/check.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
pass() { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }
expect() { # <description> <file> <text>
  if grep -q -F -- "$3" "$2"; then pass "$1"; else fail "$1"; echo "      report:"; sed 's/^/      /' "$2"; fi
}
expect_status() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected $2, got $3)"; fi
}
expect_not() { # <description> <file> <text>
  if grep -q -F -- "$3" "$2"; then fail "$1"; else pass "$1"; fi
}

case_pdf() { # <case> <output>
  uv run --quiet --python 3.13 --with pikepdf==10.16.0 python "$root/tests/check_cases.py" "$1" "$2"
}

commit_all() { # <repo> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.com commit -q -m "$2"
}

storage() { # <name> <original case or "none"> <result case>: a repository whose last commit filed one result
  local repo="$work/$1"
  git init -q -b main "$repo"
  mkdir -p "$repo/inbox/chi_sim" "$repo/done/chi_sim"
  touch "$repo/inbox/.gitkeep"
  [ "$2" = none ] || case_pdf "$2" "$repo/inbox/chi_sim/book.pdf"
  commit_all "$repo" "add a book"
  rm -f "$repo/inbox/chi_sim/book.pdf"
  case_pdf "$3" "$repo/done/chi_sim/book.pdf"
  commit_all "$repo" "chore(ocr): process 1 file(s) [skip ci]"
}

check() { # <name> [extra args]: prints the status, leaves the report in $work/<name>.md
  local name=$1
  shift
  uv run --quiet "$root/scripts/check.py" --repo "$work/$name" --report "$work/$name.md" "$@" | tail -1
}

unset CLAUDE_CODE_OAUTH_TOKEN

echo "# a good result"
storage good original result
expect_status "good result passes" success "$(check good)"
expect "pages are compared" "$work/good.md" "| book | 10 → 10 | 2 → 2 |"
expect "the blank page and the illustration are told apart" "$work/good.md" "| 1 | 1 | 0 | ✅ |"
expect "the illustration is listed as a picture" "$work/good.md" "pictures: 10"
expect "no token, no review" "$work/good.md" "not reviewed: no Claude subscription token"

echo "# broken results"
storage boxed original boxed
expect_status "boxes in the text layer fail" failure "$(check boxed)"
expect "boxes are reported" "$work/boxed.md" "the text layer draws"
storage short original short
expect_status "a missing page fails" failure "$(check short)"
expect "page counts are reported" "$work/short.md" "10 pages in the original, 9 in the result"
storage lost original lost
expect_status "lost text fails" failure "$(check lost)"
expect "lost text is reported" "$work/lost.md" "9 of 10 pages have ink but little or no text"
storage half original half
expect_status "losing half the text pages fails" failure "$(check half)"
expect "lost pages are the suspect ones" "$work/half.md" "suspect pages: 5, 6, 7, 8"
storage "long name" original result
mv "$work/long name/done/chi_sim/book.pdf" "$work/long name/done/chi_sim/书名 (某某 著) 2020 (source).pdf"
git -C "$work/long name" rm -q --cached done/chi_sim/book.pdf
git -C "$work/long name" add -A
git -C "$work/long name" -c user.name=test -c user.email=test@example.com commit -q --amend -m "process"
check "long name" >/dev/null
expect "only the title of a long file name is shown" "$work/long name.md" "| 书名 | 10 |"
storage unmarked original unmarked
expect_status "lost bookmarks fail" failure "$(check unmarked)"
expect "bookmarks are reported" "$work/unmarked.md" "2 bookmarks in the original, 0 in the result"

echo "# what there is to compare"
storage orphan none result
expect_status "a result without an original passes" success "$(check orphan)"
expect "missing original is noted" "$work/orphan.md" "no original found"
storage quiet original result
echo "notes" > "$work/quiet/README.md"
commit_all "$work/quiet" "docs"
expect_status "a commit without results passes" success "$(check quiet)"
expect "no results is noted" "$work/quiet.md" "added no results"
git init -q -b main "$work/custom"
mkdir -p "$work/custom/scans/todo"
case_pdf original "$work/custom/scans/todo/book.pdf"
commit_all "$work/custom" "add"
git -C "$work/custom" rm -q scans/todo/book.pdf
mkdir -p "$work/custom/scans/finished"
case_pdf result "$work/custom/scans/finished/book.pdf"
commit_all "$work/custom" "process"
check custom --inbox scans/todo --done scans/finished >/dev/null
expect "custom folders are followed" "$work/custom.md" "| book | 10 → 10 |"

echo "# review by Claude"
export CLAUDE_BIN="$root/tests/fake-claude/claude" FAKE_CLAUDE_LOG="$work/claude.log"
export CLAUDE_CODE_OAUTH_TOKEN=test-token ANTHROPIC_API_KEY=must-not-be-used
check good --model test-model >/dev/null
expect "verdict is added to the page" "$work/good.md" "pictures: 10 (illustration)"
expect "review is summarised" "$work/good.md" "Claude reviewed 1 of 1 flagged pages"
expect "the API key is kept from Claude" "$work/good.md" "Claude reviewed"
expect "the model is passed on" "$work/claude.log" "--model test-model"
expect "only the Read tool is allowed" "$work/claude.log" "--allowedTools Read"
FAKE_CLAUDE_VERDICT=text check good >/dev/null
expect "missed text is called out" "$work/good.md" "Claude sees text the OCR missed on pages 10"
expect "missed text is a warning" "$work/good.md" "| ⚠️ |"
FAKE_CLAUDE_SOURCE=ANTHROPIC_API_KEY check good >/dev/null
expect "an API-key run is discarded" "$work/good.md" "not using the subscription token"
expect_not "an API-key run adds no verdicts" "$work/good.md" "(illustration)"
: > "$work/claude.log"
check boxed >/dev/null
check lost --max-pages 3 >/dev/null
expect "the page budget is kept" "$work/lost.md" "Claude reviewed 3 of 9 flagged pages"
expect "the prompt asks for a note per page" "$work/claude.log" '"note"'
FAKE_CLAUDE_NOTE="Three shapes | no text" check good >/dev/null
expect "the review is collapsible" "$work/good.md" "<details><summary>Claude's review (1 page)</summary>"
expect "each reviewed page gets a row with its note" "$work/good.md" "| book | 10 | illustration | Three shapes / no text |"
check good >/dev/null
expect "an answer without notes still gives verdicts" "$work/good.md" "| book | 10 | illustration |  |"
full=$(FAKE_CLAUDE_NOTE="Three shapes" uv run --quiet "$root/scripts/check.py" --repo "$work/good" --report "$work/good.md")
if echo "$full" | grep -q "Three shapes" && [ "$(echo "$full" | tail -1)" = success ]; then pass "Claude's answer is printed for the log, status stays last"; else fail "Claude's answer is printed for the log, status stays last"; fi

echo "# report in Chinese"
FAKE_CLAUDE_NOTE="三个几何图形，没有文字" check good --language zh >/dev/null
expect "Chinese title" "$work/good.md" "### OCR 检查：通过"
expect "Chinese table header" "$work/good.md" "| 文件 | 页数 | 书签 | 字数 | 空白页 | 图页 | 可疑页 | 结果 |"
expect "Chinese verdicts" "$work/good.md" "图页：10（插图）"
expect "Chinese review table" "$work/good.md" "| book | 10 | 插图 | 三个几何图形，没有文字 |"
expect "Chinese review summary" "$work/good.md" "Claude 审阅了 1 个标记页面中的 1 个。"
unset CLAUDE_BIN FAKE_CLAUDE_LOG CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY
check short --language zh >/dev/null
expect "Chinese problems" "$work/short.md" "原件 10 页，结果 9 页"
expect "Chinese failure title" "$work/short.md" "### OCR 检查：未通过"
expect "Chinese note without a token" "$work/short.md" "标记的页面未经审阅：没有设置 Claude 订阅 token。"
expect_status "an unknown language is refused" 2 "$(uv run --quiet "$root/scripts/check.py" --repo "$work/good" --report "$work/x.md" --language fr >/dev/null 2>&1; echo $?)"

echo "# GitHub Actions output"
GITHUB_OUTPUT="$work/output" check good >/dev/null
expect "status is written for the workflow" "$work/output" "status=success"
expect "result count is written for the workflow" "$work/output" "results=1"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
