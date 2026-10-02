#!/usr/bin/env bash
# Move documents between a private storage repository and the OCR service.
# Never prints file names, the repository name or git output: the service runs
# in a public repository, so its logs are public.
#
# Usage: storage.sh fetch <dir>            clone the storage repository into <dir>
#        storage.sh save <dir> <results>   file results under done/, failures under failed/, push
#
# Environment:
#   STORAGE_REPO   owner/name of the private storage repository
#   STORAGE_TOKEN  token with read and write access to its contents
#   STORAGE_URL    full clone URL, used instead of the two above (tests, other git hosts)
set -uo pipefail

die() { echo "::error::$1" >&2; exit 2; }

fetch() { # <dir>
  local url=${STORAGE_URL:-}
  if [ -z "$url" ]; then
    [ -n "${STORAGE_REPO:-}" ] && [ -n "${STORAGE_TOKEN:-}" ] ||
      die "Set the STORAGE_REPO and STORAGE_TOKEN secrets first (see README)."
    url="https://x-access-token:${STORAGE_TOKEN}@github.com/${STORAGE_REPO}.git"
  fi
  git clone -q --depth 1 "$url" "$1" >/dev/null 2>&1 ||
    die "Cannot access the storage repository. Check STORAGE_REPO and STORAGE_TOKEN."
  mkdir -p "$1/inbox"
  echo "Fetched the storage repository."
}

save() { # <dir> <results>
  local dir=$1 results saved=0 failed=0 file name
  # No results directory means OCR never started (setup failure), not that every file failed.
  results=$(cd "$2" 2>/dev/null && pwd) || { echo "OCR did not run; inbox left untouched."; return 0; }
  cd "$dir" || die "Storage directory not found."

  shopt -s nullglob nocaseglob
  for file in inbox/*.pdf; do
    name=$(basename "$file")
    if [ -f "$results/$name" ]; then
      mkdir -p done
      mv -f "$results/$name" "done/$name"
      rm -f "$file"
      saved=$((saved + 1))
    else
      mkdir -p failed
      mv -f "$file" "failed/$name"
      failed=$((failed + 1))
    fi
  done
  shopt -u nocaseglob

  git add -A >/dev/null 2>&1
  if git diff --cached --quiet; then
    echo "Nothing to save."
    return 0
  fi

  # [skip ci] stops this push from re-triggering the storage repository's own workflow.
  git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "chore(ocr): process $((saved + failed)) file(s) [skip ci]" >/dev/null 2>&1 ||
    die "Could not commit the results."

  local attempt
  for attempt in 1 2 3; do
    if git push -q origin HEAD >/dev/null 2>&1; then
      echo "Saved $saved result(s), $failed failed."
      return 0
    fi
    # Someone pushed while OCR was running: replay our commit on top of theirs.
    git -c user.name="github-actions[bot]" \
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      pull -q --rebase >/dev/null 2>&1
  done
  die "Could not push the results to the storage repository."
}

case "${1:-}" in
  fetch) [ $# -eq 2 ] || die "usage: storage.sh fetch <dir>"; fetch "$2" ;;
  save) [ $# -eq 3 ] || die "usage: storage.sh save <dir> <results>"; save "$2" "$3" ;;
  *) die "usage: storage.sh fetch <dir> | save <dir> <results>" ;;
esac
