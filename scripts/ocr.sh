#!/usr/bin/env bash
# Add a searchable text layer to scanned PDFs using Apple's on-device OCR.
#
# Usage: ocr.sh <input.pdf> <output.pdf>
#        ocr.sh <input-dir> <output-dir>
#
# Options (environment variables):
#   OCR_LANGUAGE     one language code, e.g. eng, chi_sim, jpn (default: eng)
#   OCR_MODE         skip  = leave pages that already have text alone (default)
#                    force = rasterize and OCR every page
#   OCR_RECOGNITION  livetext | accurate | fast (default: livetext)
#   OCR_QUIET        true = never print file names or OCR output (default: false)
#   OCR_ARGS         extra arguments passed to ocrmypdf
set -uo pipefail

# Pinned so an upstream release cannot silently break OCR.
OCRMYPDF_VERSION=17.13.0
APPLEOCR_VERSION=0.4.0

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

ocrmypdf=(uvx --quiet --python 3.13
  --from "ocrmypdf==$OCRMYPDF_VERSION" --with "ocrmypdf-appleocr==$APPLEOCR_VERSION" ocrmypdf)

# Fail here, before touching any file, so a broken setup is never mistaken for bad PDFs.
command -v tesseract >/dev/null || die "tesseract is required by OCRmyPDF (brew install tesseract)"
if ! preflight=$("${ocrmypdf[@]}" --version 2>&1); then
  echo "$preflight" >&2
  die "could not install or start OCRmyPDF"
fi

ocr_file() { # <source> <destination>
  mkdir -p "$(dirname "$2")"
  local cmd=("${ocrmypdf[@]}" --ocr-engine appleocr --appleocr-recognition-mode "$recognition"
    -l "$language" --mode "$mode")
  # ${extra[@]+...} keeps bash 3.2 (macOS default) from failing on an empty array under set -u.
  if [ "$quiet" = true ]; then
    "${cmd[@]}" --quiet ${extra[@]+"${extra[@]}"} "$1" "$2" >/dev/null 2>&1
  else
    "${cmd[@]}" ${extra[@]+"${extra[@]}"} "$1" "$2"
  fi
}

if [ ! -d "$input" ]; then
  ocr_file "$input" "$output"
  exit $?
fi

shopt -s nullglob nocaseglob
files=("$input"/*.pdf)
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
  label="[$index/$total]"
  [ "$quiet" = true ] || label="$label $(basename "$file")"
  if ocr_file "$file" "$output/$(basename "$file")"; then
    echo "$label done"
  else
    echo "$label failed"
    failed=$((failed + 1))
  fi
done

echo "Processed $total file(s), $failed failed."
[ "$failed" -eq 0 ]
