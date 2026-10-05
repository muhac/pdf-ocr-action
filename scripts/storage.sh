#!/usr/bin/env bash
# Move documents between a private storage repository and the OCR service.
# Never prints file names, folder names, the repository name or git output: the
# service runs in a public repository, so its logs are public.
#
# Usage: storage.sh fetch <workdir>   clone the storage repository; its waiting PDFs appear in <workdir>/input
#        storage.sh save <workdir>    file the results from <workdir>/output, set failures aside, push
#
# Language subfolders of the inbox (inbox/chi_sim/...) keep their place: results go
# to done/chi_sim/, failures to failed/chi_sim/.
#
# Files too large for git go through releases of the storage repository. A PDF
# attached to a published release is processed when no <name>.ocr.log sits next
# to it; fetch puts it in <workdir>/release-input, and save attaches
# <name>.ocr.pdf plus <name>.ocr.log (first line: done or failed) to the same
# release. A language code on the first line of the release description selects
# the language. Deleting the log makes the next run process the file again.
#
# Environment:
#   STORAGE_REPO    owner/name of the private storage repository
#   STORAGE_TOKEN   token with read and write access to its contents
#   STORAGE_URL     full clone URL, used instead of the two above (tests, other git hosts)
#   STORAGE_INBOX   folder PDFs are taken from              (default: inbox)
#   STORAGE_DONE    folder searchable results are put in    (default: done)
#   STORAGE_FAILED  folder for PDFs that cannot be processed (default: failed)
#   STORAGE_BRANCH  branch to take PDFs from and push results to (default: the default branch)
#   OCR_LANGUAGE    language recorded in the log of release files without their own
set -uo pipefail

die() { echo "::error::$1" >&2; exit 2; }

script_dir=$(cd "$(dirname "$0")" && pwd)

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

storage_gh() { GH_TOKEN=${STORAGE_TOKEN:-} gh "$@"; }

# Release PDFs still to process, one per line, fields separated by the unit
# separator (not a tab: empty fields must survive `read`):
# tag, asset name, display label, first line of the release description.
pending_release_files() {
  # shellcheck disable=SC2016
  storage_gh api "repos/$STORAGE_REPO/releases?per_page=100" --paginate --jq '
    .[] | select(.draft | not) | . as $release
    | [.assets[].name] as $names
    | .assets[]
    | select((.name | test("\\.pdf$"; "i")) and (.name | test("\\.ocr\\.pdf$"; "i") | not))
    | (.name | sub("\\.pdf$"; ".ocr.log"; "i")) as $log
    | select($names | index($log) | not)
    | [$release.tag_name, .name, (.label // ""),
       (($release.body // "") | split("\n") | (.[0] // "") | gsub("\\s"; ""))]
    | join("\u001f")'
}

fetch_releases() {
  # Only GitHub has releases; a plain clone URL (tests, other hosts) does not.
  [ -n "${STORAGE_REPO:-}" ] || return 0
  # Releases belong to runs on the default branch; branch runs may run in parallel
  # and must not race each other for the same release.
  [ -z "${STORAGE_BRANCH:-}" ] || return 0
  local list languages code tag name label hint language rel count=0 missed=0
  list=$(pending_release_files 2>/dev/null) || {
    echo "::warning::Could not list the releases of the storage repository; skipping them."
    return 0
  }
  [ -n "$list" ] || return 0
  languages=$(<"$script_dir/languages.txt")
  mkdir -p "$work/release-input" "$work/release-jobs"
  while IFS=$'\x1f' read -r tag name label hint; do
    language=
    for code in $languages; do
      [ "$hint" = "$code" ] && language=$code
    done
    count=$((count + 1))
    # Numbered names: nothing about the release shows up in the public log.
    rel="${language:+$language/}$count.pdf"
    mkdir -p "$(dirname "$work/release-input/$rel")"
    if storage_gh release download "$tag" --repo "$STORAGE_REPO" --pattern "$name" \
      --output "$work/release-input/$rel" >/dev/null 2>&1; then
      printf '%s\n' "$tag" "$name" "$label" "$rel" > "$work/release-jobs/$count"
    else
      rm -f "$work/release-input/$rel"
      missed=$((missed + 1))
    fi
  done <<< "$list"
  echo "Fetched $((count - missed)) file(s) from releases."
  [ "$missed" -eq 0 ] || echo "::warning::Could not download $missed file(s) from releases."
}

fetch() { # <workdir>
  local url=${STORAGE_URL:-}
  if [ -z "$url" ]; then
    [ -n "${STORAGE_REPO:-}" ] && [ -n "${STORAGE_TOKEN:-}" ] ||
      die "Set the STORAGE_REPO and STORAGE_TOKEN secrets first (see README)."
    url="https://x-access-token:${STORAGE_TOKEN}@github.com/${STORAGE_REPO}.git"
  fi
  work=$(mkdir -p "$1" && cd "$1" && pwd) || die "Cannot create the work directory."
  # Only the three working folders are downloaded and checked out; the rest of
  # the repository (a document library can be large) stays on the server.
  local clone=(git clone -q --depth 1 --filter=blob:none --sparse)
  case "${STORAGE_BRANCH:-}" in
    "") ;;
    -*) die "STORAGE_BRANCH is not a valid branch name." ;;
    *) clone+=(--branch "$STORAGE_BRANCH") ;;
  esac
  "${clone[@]}" "$url" "$work/repo" >/dev/null 2>&1 ||
    die "Cannot access the storage repository or branch. Check STORAGE_REPO, STORAGE_TOKEN and the branch name."
  git -C "$work/repo" sparse-checkout set "$inbox" "$done_dir" "$failed_dir" >/dev/null 2>&1 ||
    die "Cannot check out the working folders of the storage repository."
  mkdir -p "$work/repo/$inbox"
  # A fixed name, so the configured folder never shows up in the public log.
  ln -s "$work/repo/$inbox" "$work/input"
  echo "Fetched the storage repository."
  fetch_releases
}

saved=0
failed=0

file_results() { # <subfolder, or empty for the inbox itself>
  local sub=${1:+$1/} file name
  for file in "$inbox/$sub"*.pdf; do
    name=$(basename "$file")
    if [ -f "$work/output/$sub$name" ]; then
      mkdir -p "$done_dir/$sub"
      mv -f "$work/output/$sub$name" "$done_dir/$sub$name"
      rm -f "$file"
      saved=$((saved + 1))
    else
      mkdir -p "$failed_dir/$sub"
      mv -f "$file" "$failed_dir/$sub$name"
      failed=$((failed + 1))
    fi
  done
}

save_inbox() {
  local dir
  # No output directory means OCR never started (setup failure), not that every file failed.
  [ -d "$work/output" ] || { echo "OCR did not run; inbox left untouched."; return 0; }
  cd "$work/repo" || return 1

  shopt -s nullglob nocaseglob
  file_results ""
  # OCR creates an output subfolder for each language subfolder it worked on, so
  # other inbox subfolders are left alone.
  for dir in "$work/output"/*/; do
    file_results "$(basename "$dir")"
  done
  shopt -u nocaseglob

  git add -A >/dev/null 2>&1
  if git diff --cached --quiet; then
    echo "Nothing to save."
    return 0
  fi

  # [skip ci] stops this push from re-triggering the storage repository's own workflow.
  git_as_bot commit -q -m "chore(ocr): process $((saved + failed)) file(s) [skip ci]" || {
    echo "::error::Could not commit the results."
    return 1
  }

  for _ in 1 2 3; do
    if git push -q origin HEAD >/dev/null 2>&1; then
      echo "Saved $saved result(s), $failed failed."
      return 0
    fi
    # Someone pushed while OCR was running: replay our commit on top of theirs.
    # Directory rename detection stays off: when the user files everything out
    # of done/, git would otherwise insist on moving the new results along too.
    if ! git_as_bot -c merge.directoryRenames=false pull -q --rebase; then
      git rebase --abort >/dev/null 2>&1
      break
    fi
  done
  echo "::error::Could not push the results to the storage repository."
  return 1
}

attach() { # <tag> <file> <display label, or empty>
  storage_gh release upload "$1" "$2${3:+#$3}" --repo "$STORAGE_REPO" --clobber >/dev/null 2>&1
}

save_releases() {
  [ -d "$work/release-jobs" ] || return 0
  # No output directory means OCR never started on the release files: write no
  # logs, so the next run picks them up again.
  [ -d "$work/release-output" ] || { echo "OCR did not run on the release files."; return 0; }
  local job tag name label rel stem label_stem upload language status done_count=0 failed_count=0 errors=0
  shopt -s nullglob
  for job in "$work/release-jobs"/*; do
    { IFS= read -r tag; IFS= read -r name; IFS= read -r label; IFS= read -r rel; } < "$job"
    stem=${name%.*}
    label_stem=${label%.*}
    upload="$work/release-upload/$(basename "$job")"
    mkdir -p "$upload"
    status=failed
    if [ -f "$work/release-output/$rel" ]; then
      mv -f "$work/release-output/$rel" "$upload/$stem.ocr.pdf"
      # The log is what marks a file as processed, so it is only written once the result is up.
      attach "$tag" "$upload/$stem.ocr.pdf" "${label:+$label_stem.ocr.pdf}" || { errors=$((errors + 1)); continue; }
      status="done"
    fi
    case "$rel" in
      */*) language=${rel%%/*} ;;
      *) language=${OCR_LANGUAGE:-eng} ;;
    esac
    printf '%s\n%s %s\n' "$status" "$(date -u +%Y-%m-%d)" "$language" > "$upload/$stem.ocr.log"
    attach "$tag" "$upload/$stem.ocr.log" "${label:+$label_stem.ocr.log}" || { errors=$((errors + 1)); continue; }
    if [ "$status" = "done" ]; then done_count=$((done_count + 1)); else failed_count=$((failed_count + 1)); fi
  done
  echo "Releases: saved $done_count result(s), $failed_count failed."
  [ "$errors" -eq 0 ] || { echo "::error::Could not attach $errors file(s) to releases."; return 1; }
}

save() { # <workdir>
  local status=0
  work=$(cd "$1" 2>/dev/null && pwd) && [ -d "$work/repo" ] || die "Nothing was fetched."
  save_inbox || status=1
  save_releases || status=1
  return $status
}

case "${1:-}" in
  fetch | save) [ $# -eq 2 ] || die "usage: storage.sh $1 <workdir>"; "$1" "$2" ;;
  *) die "usage: storage.sh fetch <workdir> | save <workdir>" ;;
esac
