#!/usr/bin/env bash
# Move documents between a private storage repository and the OCR service.
# Never prints file names, folder names, the repository name or git output: the
# service runs in a public repository, so its logs are public.
#
# Usage: storage.sh fetch <workdir>   clone the storage repository; its waiting PDFs appear in <workdir>/input
#        storage.sh save <workdir>    file the results from <workdir>/output, set failures aside, push
#
# Environment:
#   STORAGE_REPO    owner/name of the private storage repository
#   STORAGE_TOKEN   token with read and write access to its contents
#   STORAGE_URL     full clone URL, used instead of the two above (tests, other git hosts)
#   STORAGE_INBOX   folder PDFs are taken from              (default: inbox)
#   STORAGE_DONE    folder searchable results are put in    (default: done)
#   STORAGE_FAILED  folder for PDFs that cannot be processed (default: failed)
set -uo pipefail

die() { echo "::error::$1" >&2; exit 2; }

inbox=${STORAGE_INBOX:-inbox}
done_dir=${STORAGE_DONE:-done}
failed_dir=${STORAGE_FAILED:-failed}
inbox=${inbox%/}
done_dir=${done_dir%/}
failed_dir=${failed_dir%/}

check_folder() { # <setting> <value>
  case "/$2/" in
    //* | */../* | */./* | /.git/*) die "$1 must be a folder inside the storage repository." ;;
  esac
}
check_folder STORAGE_INBOX "$inbox"
check_folder STORAGE_DONE "$done_dir"
check_folder STORAGE_FAILED "$failed_dir"
[ "$inbox" != "$done_dir" ] && [ "$inbox" != "$failed_dir" ] ||
  die "STORAGE_DONE and STORAGE_FAILED must be different folders from STORAGE_INBOX."

git_as_bot() {
  git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" "$@" >/dev/null 2>&1
}

fetch() { # <workdir>
  local work url=${STORAGE_URL:-}
  if [ -z "$url" ]; then
    [ -n "${STORAGE_REPO:-}" ] && [ -n "${STORAGE_TOKEN:-}" ] ||
      die "Set the STORAGE_REPO and STORAGE_TOKEN secrets first (see README)."
    url="https://x-access-token:${STORAGE_TOKEN}@github.com/${STORAGE_REPO}.git"
  fi
  work=$(mkdir -p "$1" && cd "$1" && pwd) || die "Cannot create the work directory."
  git clone -q --depth 1 "$url" "$work/repo" >/dev/null 2>&1 ||
    die "Cannot access the storage repository. Check STORAGE_REPO and STORAGE_TOKEN."
  mkdir -p "$work/repo/$inbox"
  # A fixed name, so the configured folder never shows up in the public log.
  ln -s "$work/repo/$inbox" "$work/input"
  echo "Fetched the storage repository."
}

save() { # <workdir>
  local work saved=0 failed=0 file name
  work=$(cd "$1" 2>/dev/null && pwd) && [ -d "$work/repo" ] || die "Nothing was fetched."
  # No output directory means OCR never started (setup failure), not that every file failed.
  [ -d "$work/output" ] || { echo "OCR did not run; inbox left untouched."; return 0; }
  cd "$work/repo" || die "Nothing was fetched."

  shopt -s nullglob nocaseglob
  for file in "$inbox"/*.pdf; do
    name=$(basename "$file")
    if [ -f "$work/output/$name" ]; then
      mkdir -p "$done_dir"
      mv -f "$work/output/$name" "$done_dir/$name"
      rm -f "$file"
      saved=$((saved + 1))
    else
      mkdir -p "$failed_dir"
      mv -f "$file" "$failed_dir/$name"
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
  git_as_bot commit -q -m "chore(ocr): process $((saved + failed)) file(s) [skip ci]" ||
    die "Could not commit the results."

  for _ in 1 2 3; do
    if git push -q origin HEAD >/dev/null 2>&1; then
      echo "Saved $saved result(s), $failed failed."
      return 0
    fi
    # Someone pushed while OCR was running: replay our commit on top of theirs.
    git_as_bot pull -q --rebase
  done
  die "Could not push the results to the storage repository."
}

case "${1:-}" in
  fetch | save) [ $# -eq 2 ] || die "usage: storage.sh $1 <workdir>"; "$1" "$2" ;;
  *) die "usage: storage.sh fetch <workdir> | save <workdir>" ;;
esac
