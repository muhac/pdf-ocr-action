# /// script
# requires-python = ">=3.11"
# dependencies = ["pikepdf==10.16.0", "pypdfium2==5.13.0", "pillow==12.3.0"]
#
# [tool.uv]
# exclude-newer = "2026-10-02T00:00:00Z"
# ///
"""Check the OCR results that one commit of a storage repository added.

For every PDF the commit added under the results folder, the original is read
from the parent commit's inbox folder and the two are compared: page count,
bookmarks, leftover drawing in the text layer, and, page by page, how much text
was recognised against how much ink is on the page. A page inked like the
book's text pages but carrying far less text is "suspect" (OCR probably lost
it); a page with unusual ink and little text is a "picture". With a Claude
subscription token both can be shown to Claude, who says whether each one is
blank, an illustration or missed text.

Usage: uv run check.py --repo PATH --commit SHA --report report.md
                       [--inbox inbox] [--done done] [--max-pages 20] [--model M]

Prints the status (success or failure) as the last line and, inside GitHub
Actions, also writes it to GITHUB_OUTPUT.
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import pikepdf
import pypdfium2 as pdfium

DRAWING = {"RG", "rg", "w", "m", "l", "h", "re", "S", "s", "f", "B"}
# Tuned on 22 books and one run that lost text: that run had 24% suspect pages,
# no good book more than 4%.
RENDER_WIDTH = 600  # pixels; a fixed width keeps ink comparable between page sizes
BLANK_INK = 0.5  # percent of dark pixels below which a page counts as empty
LOW_TEXT = 0.4  # share of the book's usual text per ink below which a page has too little
TEXT_INK = (0.5, 2.0)  # ink range, relative to the book's text pages, of a page meant to hold text
NORMAL_PAGE_CHARS = 50
VERDICTS = ("blank", "illustration", "text")


@dataclass
class Book:
    path: str
    original_found: bool = False
    error: str = ""
    pages: int = 0
    original_pages: int = 0
    bookmarks: int = 0
    original_bookmarks: int = 0
    drawing: int = 0
    chars: int = 0
    blank: list[int] = field(default_factory=list)
    pictures: list[int] = field(default_factory=list)
    suspect: list[int] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    verdicts: dict[int, str] = field(default_factory=dict)

    @property
    def systematic(self) -> bool:
        return len(self.suspect) > max(3, self.pages // 10)

    @property
    def failed(self) -> bool:
        return bool(self.error or self.problems or self.systematic)


def git(repo: str, *args: str, binary: bool = False):
    result = subprocess.run(["git", "-C", repo, "-c", "core.quotepath=false", *args],
                            capture_output=True, text=not binary)
    return result


def added_results(repo: str, commit: str, done: str) -> list[str]:
    out = git(repo, "diff", "--name-status", "--no-renames", "-z", f"{commit}^", commit).stdout
    fields = out.split("\0")
    added = []
    for status, path in zip(fields[0::2], fields[1::2]):
        if status == "A" and path.startswith(f"{done}/") and path.lower().endswith(".pdf"):
            added.append(path)
    return added


def show(repo: str, spec: str, dest: Path) -> bool:
    result = git(repo, "show", spec, binary=True)
    if result.returncode != 0:
        return False
    dest.write_bytes(result.stdout)
    return True


def structure(path: Path) -> tuple[int, int, int]:
    """Pages, bookmarks, and drawing instructions inside OCR text layers."""
    with pikepdf.open(path) as pdf:
        with pdf.open_outline() as outline:
            def count(items):
                return sum(1 + count(item.children) for item in items)
            bookmarks = count(outline.root)
        drawing = 0
        for page in pdf.pages:
            for name, layer in (page.resources.get("/XObject") or {}).items():
                if str(name).startswith("/OCR-"):
                    drawing += sum(1 for _, op in pikepdf.parse_content_stream(layer) if str(op) in DRAWING)
        return len(pdf.pages), bookmarks, drawing


def page_measures(path: Path) -> list[tuple[int, float]]:
    """Characters of text and percent of dark pixels, for every page."""
    doc = pdfium.PdfDocument(path)
    measures = []
    for page in doc:
        chars = len("".join(page.get_textpage().get_text_range().split()))
        pixels = page.render(scale=RENDER_WIDTH / page.get_width(), grayscale=True).to_pil().convert("L").tobytes()
        ink = 100 * sum(1 for v in pixels if v < 160) / max(1, len(pixels))
        measures.append((chars, ink))
    doc.close()
    return measures


def classify(book: Book, measures: list[tuple[int, float]]) -> None:
    book.chars = sum(chars for chars, _ in measures)
    normal = [(chars, ink) for chars, ink in measures if chars >= NORMAL_PAGE_CHARS and ink >= BLANK_INK]
    density = statistics.median(chars / ink for chars, ink in normal) if normal else None
    text_ink = statistics.median(ink for _, ink in normal) if normal else None
    for number, (chars, ink) in enumerate(measures, 1):
        if ink < BLANK_INK:
            if chars == 0:
                book.blank.append(number)
            continue
        if density is None:  # no page has normal text, so every inked page lacks it
            if chars < NORMAL_PAGE_CHARS:
                book.suspect.append(number)
            continue
        if chars >= LOW_TEXT * density * ink:
            continue
        if TEXT_INK[0] <= ink / text_ink <= TEXT_INK[1]:
            book.suspect.append(number)
        else:
            book.pictures.append(number)


def check_book(repo: str, commit: str, path: str, inbox: str, done: str, work: Path) -> Book:
    book = Book(path)
    result, original = work / "result.pdf", work / "original.pdf"
    if not show(repo, f"{commit}:{path}", result):
        book.error = "result could not be read from the commit"
        return book
    book.original_found = show(repo, f"{commit}^:{inbox}/{path[len(done) + 1:]}", original)
    try:
        book.pages, book.bookmarks, book.drawing = structure(result)
        classify(book, page_measures(result))
    except Exception as e:  # a damaged result is a finding, not a crash
        book.error = f"result could not be opened: {e}"
        return book
    if book.original_found:
        try:
            book.original_pages, book.original_bookmarks, _ = structure(original)
        except Exception as e:
            book.problems.append(f"original could not be opened: {e}")
        else:
            if book.pages != book.original_pages:
                book.problems.append(f"{book.original_pages} pages in the original, {book.pages} in the result")
            if book.bookmarks != book.original_bookmarks:
                book.problems.append(f"{book.original_bookmarks} bookmarks in the original, {book.bookmarks} in the result")
    if book.drawing:
        book.problems.append(f"the text layer draws {book.drawing} visible shapes")
    if book.systematic:
        book.problems.append(f"{len(book.suspect)} of {book.pages} pages have ink but little or no text")
    return book


def ask_claude(repo: str, commit: str, books: list[Book], max_pages: int, model: str) -> str:
    """Show suspect pages to Claude. Returns a note for the report."""
    if not os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        return "Flagged pages were not reviewed: no Claude subscription token is set."
    # Suspect pages first, then pictures; within each, spread the budget across books.
    queue = []
    for kind in ("suspect", "pictures"):
        pages = [(rank, i, page) for i, book in enumerate(books) for rank, page in enumerate(getattr(book, kind))]
        queue += [(i, page) for _, i, page in sorted(pages)]
    if not queue:
        return ""
    total = len(queue)
    queue = queue[:max_pages]
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp) / "pages"
        folder.mkdir()
        names = {}
        for i, book in enumerate(books):
            wanted = [page for j, page in queue if j == i]
            if not wanted:
                continue
            pdf = Path(tmp) / f"{i}.pdf"
            show(repo, f"{commit}:{book.path}", pdf)
            doc = pdfium.PdfDocument(pdf)
            for page in wanted:
                name = f"book{i + 1}-page{page}.png"
                doc[page - 1].render(scale=1.5).to_pil().save(folder / name)
                names[name] = (i, page)
            doc.close()
        prompt = (
            "Each PNG file listed below is one page of a scanned book. OCR found little or no text "
            "on these pages. Read every file and classify the page as \"blank\" (empty or nearly empty), "
            "\"illustration\" (pictures, diagrams, decorations or title art, with at most a few words), or "
            "\"text\" (lines or paragraphs of printed text that OCR should have recognised). Reply with "
            "only a JSON object that maps each file name to one of those three words.\n\nFiles: "
            + ", ".join(sorted(names))
        )
        env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")}
        try:
            run = subprocess.run(
                [os.environ.get("CLAUDE_BIN", "claude"), "-p", prompt, "--model", model,
                 "--allowedTools", "Read", "--max-turns", str(len(names) + 5),
                 "--output-format", "stream-json", "--verbose"],
                cwd=folder, env=env, capture_output=True, text=True, timeout=900,
            )
        except (OSError, subprocess.TimeoutExpired) as e:
            return f"Flagged pages were not reviewed: Claude did not run ({e.__class__.__name__})."
    source, answer = None, None
    for line in run.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "system" and event.get("subtype") == "init":
            source = event.get("apiKeySource")
        if event.get("type") == "result" and not event.get("is_error"):
            answer = event.get("result", "")
    if source != "none":
        return f"Flagged pages were not reviewed: Claude was not using the subscription token (credential: {source})."
    if answer is None:
        return "Flagged pages were not reviewed: Claude returned no answer."
    try:
        verdicts = json.loads(answer[answer.index("{"): answer.rindex("}") + 1])
    except ValueError:
        return "Flagged pages were not reviewed: Claude's answer was not JSON."
    for name, verdict in verdicts.items():
        if name in names and verdict in VERDICTS:
            i, page = names[name]
            books[i].verdicts[page] = verdict
    reviewed = sum(len(book.verdicts) for book in books)
    return f"Claude reviewed {reviewed} of {total} flagged pages."


def short_name(path: str, limit: int = 30) -> str:
    """The title part of a file name: what comes before author and source in parentheses."""
    stem = Path(path).stem.split(" (")[0]
    return stem if len(stem) <= limit else stem[:limit] + "…"


def pages_text(pages: list[int], verdicts: dict[int, str], limit: int = 30) -> str:
    shown = ", ".join(f"{p} ({verdicts[p]})" if p in verdicts else str(p) for p in pages[:limit])
    return shown + (f" and {len(pages) - limit} more" if len(pages) > limit else "")


def report(books: list[Book], note: str) -> tuple[str, str]:
    status = "failure" if any(book.failed for book in books) else "success"
    lines = [f"### OCR check: {'passed' if status == 'success' else 'failed'}", ""]
    if not books:
        lines.append("This commit added no results.")
        return "\n".join(lines) + "\n", status
    lines += ["| File | Pages | Bookmarks | Characters | Blank | Pictures | Suspect | Result |",
              "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for book in books:
        name = short_name(book.path)
        if book.error:
            lines.append(f"| {name} | | | | | | | ❌ {book.error} |")
            continue
        def pair(result, original):
            return f"{original} → {result}" if book.original_found else f"{result}"
        mark = "❌" if book.failed else ("⚠️" if any(v == "text" for v in book.verdicts.values()) else "✅")
        lines.append(f"| {name} | {pair(book.pages, book.original_pages)} | "
                     f"{pair(book.bookmarks, book.original_bookmarks)} | {book.chars:,} | {len(book.blank)} | "
                     f"{len(book.pictures)} | {len(book.suspect)} | {mark} |")
    lines.append("")
    for book in books:
        name = short_name(book.path)
        details = list(book.problems)
        if not book.original_found and not book.error:
            details.append("no original found in the parent commit, so nothing was compared")
        if book.suspect:
            details.append(f"suspect pages: {pages_text(book.suspect, book.verdicts)}")
        if book.pictures:
            details.append(f"pictures: {pages_text(book.pictures, book.verdicts)}")
        missed = [p for p, v in book.verdicts.items() if v == "text"]
        if missed:
            details.append(f"Claude sees text the OCR missed on pages {', '.join(map(str, sorted(missed)))}")
        if details:
            lines.append(f"**{name}**")
            lines += [f"- {d}" for d in details]
            lines.append("")
    if note:
        lines.append(note)
    return "\n".join(lines).rstrip() + "\n", status


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--commit", default="HEAD")
    parser.add_argument("--inbox", default="inbox")
    parser.add_argument("--done", default="done")
    parser.add_argument("--report", required=True)
    parser.add_argument("--max-pages", type=int, default=20)
    parser.add_argument("--model", default="claude-sonnet-5-5")
    args = parser.parse_args()
    inbox, done = args.inbox.strip("/"), args.done.strip("/")
    commit = git(args.repo, "rev-parse", args.commit).stdout.strip()
    if not commit:
        sys.exit(f"unknown commit: {args.commit}")

    books = []
    with tempfile.TemporaryDirectory() as tmp:
        for path in added_results(args.repo, commit, done):
            books.append(check_book(args.repo, commit, path, inbox, done, Path(tmp)))
    note = ask_claude(args.repo, commit, books, args.max_pages, args.model) if books else ""
    text, status = report(books, note)
    Path(args.report).write_text(text)
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"status={status}\nresults={len(books)}\n")
    print(status)


if __name__ == "__main__":
    main()
