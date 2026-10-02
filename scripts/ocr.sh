#!/usr/bin/env bash
# Add a searchable text layer to scanned PDFs using Apple's on-device OCR.
#
# Usage: ocr.sh <input.pdf> <output.pdf>
#        ocr.sh <input-dir> <output-dir>
#
# In a directory, PDFs inside a subfolder named after a language code (chi_sim/,
# jpn/, ...) are read in that language; the output keeps the same subfolder.
#
# Options (environment variables):
#   OCR_LANGUAGE     one language code, e.g. eng, chi_sim, jpn (default: eng);
#                    in a directory, the language for PDFs outside language subfolders
#   OCR_MODE         skip  = leave pages that already have text alone (default)
#                    force = rasterize and OCR every page
#   OCR_RECOGNITION  livetext | accurate | fast (default: livetext)
#   OCR_QUIET        true = never print file names or OCR output (default: false)
#   OCR_ARGS         extra arguments passed to ocrmypdf
set -uo pipefail

# Pinned so an upstream release cannot silently break OCR. The date freezes the
# packages those two depend on; move it forward when bumping the versions.
OCRMYPDF_VERSION=17.13.0
APPLEOCR_VERSION=0.4.0
PACKAGES_AS_OF=2026-10-02T00:00:00Z
# Languages of the pinned plugin version; these are the recognized subfolder names.
LANGUAGES=$(<"$(dirname "$0")/languages.txt")

die() { echo "error: $1" >&2; exit 2; }

[ "$(uname)" = Darwin ] || die "Apple OCR is only available on macOS"
command -v uvx >/dev/null || die "uv is required (https://docs.astral.sh/uv/)"
[ $# -eq 2 ] || die "usage: ocr.sh <input.pdf|input-dir> <output.pdf|output-dir>"

input=$1
output=$2
language=${OCR_LANGUAGE:-eng}
mode=${OCR_MODE:-skip}
recognition=${OCR_RECOGNITION:-livetext}
quiet=${OCR_QUIET:-false}

case "$mode" in skip | force) ;; *) die "OCR_MODE must be skip or force" ;; esac
case "$recognition" in livetext | accurate | fast) ;; *) die "OCR_RECOGNITION must be livetext, accurate or fast" ;; esac
case "$language" in *+*) die "only one language per run is supported" ;; esac
[ -e "$input" ] || die "input not found"

extra=()
# shellcheck disable=SC2206
[ -n "${OCR_ARGS:-}" ] && extra=($OCR_ARGS)

ocrmypdf=(uvx --quiet --python 3.13 --exclude-newer "$PACKAGES_AS_OF"
  --from "ocrmypdf==$OCRMYPDF_VERSION" --with "ocrmypdf-appleocr==$APPLEOCR_VERSION" ocrmypdf)

# Fail here, before touching any file, so a broken setup is never mistaken for bad PDFs.
command -v tesseract >/dev/null || die "tesseract is required by OCRmyPDF (brew install tesseract)"
if ! preflight=$("${ocrmypdf[@]}" --version 2>&1); then
  echo "$preflight" >&2
  die "could not install or start OCRmyPDF"
fi

ocr_file() { # <source> <destination> <language>
  mkdir -p "$(dirname "$2")"
  local cmd=("${ocrmypdf[@]}" --ocr-engine appleocr --appleocr-recognition-mode "$recognition"
    -l "$3" --mode "$mode")
  # ${extra[@]+...} keeps bash 3.2 (macOS default) from failing on an empty array under set -u.
  if [ "$quiet" = true ]; then
    "${cmd[@]}" --quiet ${extra[@]+"${extra[@]}"} "$1" "$2" >/dev/null 2>&1
  else
    "${cmd[@]}" ${extra[@]+"${extra[@]}"} "$1" "$2"
  fi
}

if [ ! -d "$input" ]; then
  ocr_file "$input" "$output" "$language"
  exit $?
fi

input=${input%/}
shopt -s nullglob nocaseglob
files=("$input"/*.pdf)
for code in $LANGUAGES; do
  [ -d "$input/$code" ] && files+=("$input/$code"/*.pdf)
done
shopt -u nocaseglob

total=${#files[@]}
if [ "$total" -eq 0 ]; then
  echo "No PDF files to process."
  exit 0
fi

mkdir -p "$output"
failed=0
index=0
for file in "${files[@]}"; do
  index=$((index + 1))
  name=${file#"$input"/}
  case "$name" in
    */*) file_language=${name%%/*} ;;
    *) file_language=$language ;;
  esac
  label="[$index/$total]"
  [ "$quiet" = true ] || label="$label $name"
  if ocr_file "$file" "$output/$name" "$file_language"; then
    echo "$label done"
  else
    echo "$label failed"
    failed=$((failed + 1))
  fi
done

echo "Processed $total file(s), $failed failed."
[ "$failed" -eq 0 ]
