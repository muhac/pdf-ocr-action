# AGENTS.md

Guidance for AI agents working in this repository. `README.md` describes the project for users.

## Layout

| Path | What it is |
| --- | --- |
| `action.yml`, `scripts/ocr.sh`, `scripts/strip_boxes.py` | The OCR action (macOS only) |
| `trigger/action.yml` | Starts the OCR service from a documents repository |
| `check/action.yml`, `scripts/check.py` | Compares results with their originals (any OS) |
| `.github/workflows/ocr.yml`, `scripts/storage.sh` | The OCR service |
| `tests/run.sh` | End-to-end tests with real OCR (macOS) |
| `tests/check.sh` | Tests for the check (any OS) |

## This repository is public, and so are its Actions logs

- Never write the name of anyone's documents repository, or file, folder, branch or book names, into code, tests, commits, issues or release notes. Tests use neutral names such as `private-scan.pdf`.
- The service logs counts only. Branch names are masked; secrets hold the repository and folder names. Keep it that way when changing `ocr.yml` or `storage.sh`, and keep the tests that grep the log for names.

## Making changes

- Tests first for anything non-trivial, then the change. `shellcheck` and `actionlint` must be clean.
- Versions are pinned on purpose: OCRmyPDF, the AppleOCR plugin and the dependency date in `scripts/ocr.sh`; the packages in the header of `scripts/check.py`; Claude Code in `check/action.yml`. Bump them only on purpose, with the tests run on both macOS versions.
- The default runner is `macos-15`: on `macos-26`, Traditional Chinese loses much of its text.
- Claude in the check uses a subscription token only. Do not add API-key paths. `--bare` (to become the default for `claude -p`) ignores subscription tokens, which is why Claude Code is pinned.
- Commits follow conventional commits, e.g. `fix(service): …`, `feat(check): …`.

## Versions and the release page

There is one release page, attached to the floating `v1` tag. Everything else is a plain tag.

| Change | Tag | `v1` | Release page |
| --- | --- | --- | --- |
| New feature or changed behaviour | next minor, e.g. `v1.7.0` | move | update |
| Fix | next patch, e.g. `v1.6.1` | move | leave as is |
| Docs or tests only | none | leave | leave |

- Tag only a `main` commit whose Test workflow passed.
- Moving `v1` means force-updating the tag (`git tag -f v1 <sha>` and `git push origin +refs/tags/v1:refs/tags/v1`). This is the repository's standing practice.
- Updating the page: `gh release edit v1 --notes-file <file>`. In both languages, change the "Current version · updated" line and add the minor version to the top of "Changes by minor version". Read the current notes first with `gh release view v1 --json body -q .body` and edit them; do not rewrite from scratch.
- Do not create other release pages. A major version gets one floating page of its own on `v2`, and the `v1` page then stays at the last 1.x version.
