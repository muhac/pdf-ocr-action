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
subscription token both can be shown to Claude next to the text OCR found on
them, and Claude says whether each one is blank, an illustration, or text that
OCR captured or missed.

Usage: uv run check.py --repo PATH --commit SHA --report report.md
                       [--inbox inbox] [--done done] [--max-pages 20] [--model M]
                       [--language en|zh]

Prints Claude's answer, if any, then the status (success or failure) as the
last line; inside GitHub Actions the status also goes to GITHUB_OUTPUT.
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
VERDICTS = ("blank", "illustration", "captured", "missed")
BATCH = 10  # pages per conversation with Claude
IMAGE_EDGE = 1568  # pixels on the long edge of a page image shown to Claude

STRINGS = {
    "en": {
        "passed": "### OCR check: passed", "failed": "### OCR check: failed",
        "no_results": "This commit added no results.",
        "header": "| File | Pages | Bookmarks | Characters | Blank | Pictures | Suspect | Result |",
        "unreadable": "result could not be read from the commit",
        "unopenable": "result could not be opened: {error}",
        "original_unopenable": "original could not be opened: {error}",
        "pages": "{original} pages in the original, {result} in the result",
        "bookmarks": "{original} bookmarks in the original, {result} in the result",
        "drawing": "the text layer draws {count} visible shapes",
        "systematic": "{count} of {pages} pages have ink but little or no text",
        "no_original": "no original found in the parent commit, so nothing was compared",
        "suspect": "suspect pages: {pages}", "pictures": "pictures: {pages}",
        "missed": "Claude finds text missing from the OCR on pages {pages}",
        "page": "{page} ({verdict})", "sep": ", ", "more": " and {count} more",
        "verdicts": {"blank": "blank", "illustration": "illustration", "captured": "captured", "missed": "missed"},
        "review": "Claude's review ({count} {unit})", "units": ("page", "pages"),
        "review_header": "| File | Page | Verdict | Note |",
        "no_token": "Flagged pages were not reviewed: no Claude subscription token is set.",
        "not_run": "Flagged pages were not reviewed: Claude did not run ({error}).",
        "not_subscription": "Flagged pages were not reviewed: Claude was not using the subscription token (credential: {source}).",
        "no_answer": "Flagged pages were not reviewed: Claude returned no answer.",
        "not_json": "Flagged pages were not reviewed: Claude's answer was not JSON.",
        "reviewed": "Claude reviewed {reviewed} of {total} flagged pages.",
    },
    "zh": {
        "passed": "### OCR 检查：通过", "failed": "### OCR 检查：未通过",
        "no_results": "这次提交没有新增识别结果。",
        "header": "| 文件 | 页数 | 书签 | 字数 | 空白页 | 图页 | 可疑页 | 结果 |",
        "unreadable": "无法从提交中读取结果",
        "unopenable": "结果无法打开：{error}",
        "original_unopenable": "原件无法打开：{error}",
        "pages": "原件 {original} 页，结果 {result} 页",
        "bookmarks": "原件 {original} 条书签，结果 {result} 条",
        "drawing": "文字层画出了 {count} 个可见图形",
        "systematic": "{pages} 页中有 {count} 页有墨迹但几乎没有文字",
        "no_original": "上一个提交里没有找到原件，未做对比",
        "suspect": "可疑页：{pages}", "pictures": "图页：{pages}",
        "missed": "Claude 认为这些页漏识别了文字：{pages}",
        "page": "{page}（{verdict}）", "sep": "、", "more": "，另有 {count} 页",
        "verdicts": {"blank": "空白", "illustration": "插图", "captured": "已识别", "missed": "漏识别"},
        "review": "Claude 的判断（{count} 页）", "units": ("", ""),
        "review_header": "| 文件 | 页 | 判断 | 说明 |",
        "no_token": "标记的页面未经审阅：没有设置 Claude 订阅 token。",
        "not_run": "标记的页面未经审阅：Claude 没有运行（{error}）。",
        "not_subscription": "标记的页面未经审阅：Claude 没有使用订阅 token（凭据：{source}）。",
        "no_answer": "标记的页面未经审阅：Claude 没有给出回答。",
        "not_json": "标记的页面未经审阅：Claude 的回答不是 JSON。",
        "reviewed": "Claude 审阅了 {total} 个标记页面中的 {reviewed} 个。",
    },
}
T = STRINGS["en"]


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
    notes: dict[int, str] = field(default_factory=dict)

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
        book.error = T["unreadable"]
        return book
    book.original_found = show(repo, f"{commit}^:{inbox}/{path[len(done) + 1:]}", original)
    try:
        book.pages, book.bookmarks, book.drawing = structure(result)
        classify(book, page_measures(result))
    except Exception as e:  # a damaged result is a finding, not a crash
        book.error = T["unopenable"].format(error=e)
        return book
    if book.original_found:
        try:
            book.original_pages, book.original_bookmarks, _ = structure(original)
        except Exception as e:
            book.problems.append(T["original_unopenable"].format(error=e))
        else:
            if book.pages != book.original_pages:
                book.problems.append(T["pages"].format(original=book.original_pages, result=book.pages))
            if book.bookmarks != book.original_bookmarks:
                book.problems.append(T["bookmarks"].format(original=book.original_bookmarks, result=book.bookmarks))
    if book.drawing:
        book.problems.append(T["drawing"].format(count=book.drawing))
    if book.systematic:
        book.problems.append(T["systematic"].format(count=len(book.suspect), pages=book.pages))
    return book


PROMPT = """Each page of a scanned book listed below comes as two files: bookN-pageM.png is an
image of the page, and bookN-pageM.txt is the text that OCR recognised on that page (it may
be empty). Read both files for every page and classify the page as:

- "blank": empty or nearly empty;
- "illustration": pictures, diagrams, decorations or title art, with at most a few words;
- "captured": the page has printed text and the OCR text contains essentially all of it
  (small character errors are fine);
- "missed": the page has printed text that is missing from the OCR text, such as whole
  lines or paragraphs.

Reply with only a JSON object that maps each page's PNG file name to an object with two
keys: "verdict", one of those four words, and "note", one short sentence in the language
the book is written in that says what is on the page and, for "missed", what the OCR text
lacks.

Pages: {pages}"""


def claude_batch(folder: Path, names: list[str], model: str) -> tuple[str | None, str | None]:
    """Run Claude on one folder of pages. Returns (error note, answer)."""
    env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")}
    try:
        run = subprocess.run(
            [os.environ.get("CLAUDE_BIN", "claude"), "-p", PROMPT.format(pages=", ".join(names)),
             "--model", model, "--allowedTools", "Read", "--max-turns", str(2 * len(names) + 5),
             "--output-format", "stream-json", "--verbose"],
            cwd=folder, env=env, capture_output=True, text=True, timeout=1800,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        return T["not_run"].format(error=e.__class__.__name__), None
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
        return T["not_subscription"].format(source=source), None
    if answer is None:
        return T["no_answer"], None
    return None, answer


def ask_claude(repo: str, commit: str, books: list[Book], max_pages: int, model: str) -> str:
    """Show flagged pages, with the text OCR found on them, to Claude. Returns a note for the report."""
    if not os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        return T["no_token"]
    # Suspect pages first, then pictures; within each, spread the budget across books.
    queue = []
    for kind in ("suspect", "pictures"):
        pages = [(rank, i, page) for i, book in enumerate(books) for rank, page in enumerate(getattr(book, kind))]
        queue += [(i, page) for _, i, page in sorted(pages)]
    if not queue:
        return ""
    total = len(queue)
    if max_pages > 0:
        queue = queue[:max_pages]
    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        docs = {}
        for i, book in enumerate(books):
            if any(j == i for j, _ in queue):
                show(repo, f"{commit}:{book.path}", Path(tmp) / f"{i}.pdf")
                docs[i] = pdfium.PdfDocument(Path(tmp) / f"{i}.pdf")
        # Small batches keep each conversation short, which keeps the judgement sharp.
        for start in range(0, len(queue), BATCH):
            folder = Path(tmp) / f"batch{start // BATCH}"
            folder.mkdir()
            names = {}
            for i, page in queue[start:start + BATCH]:
                stem = f"book{i + 1}-page{page}"
                pdf_page = docs[i][page - 1]
                scale = IMAGE_EDGE / max(pdf_page.get_width(), pdf_page.get_height())
                pdf_page.render(scale=scale).to_pil().save(folder / f"{stem}.png")
                (folder / f"{stem}.txt").write_text(pdf_page.get_textpage().get_text_range())
                names[f"{stem}.png"] = (i, page)
            error, answer = claude_batch(folder, sorted(names), model)
            if error:
                problems.append(error)
                continue
            # The full answer goes to the log of the (private) repository running the check.
            print(f"Claude's answer:\n{answer}")
            try:
                verdicts = json.loads(answer[answer.index("{"): answer.rindex("}") + 1])
            except ValueError:
                problems.append(T["not_json"])
                continue
            for name, value in verdicts.items():
                verdict, note = (value.get("verdict"), value.get("note")) if isinstance(value, dict) else (value, None)
                if name in names and verdict in VERDICTS:
                    i, page = names[name]
                    books[i].verdicts[page] = verdict
                    if isinstance(note, str):
                        books[i].notes[page] = " ".join(note.replace("|", "/").split())
        for doc in docs.values():
            doc.close()
    reviewed = sum(len(book.verdicts) for book in books)
    if not reviewed and problems:
        return problems[0]
    return " ".join([T["reviewed"].format(reviewed=reviewed, total=total), *sorted(set(problems))])


def short_name(path: str, limit: int = 30) -> str:
    """The title part of a file name: what comes before author and source in parentheses."""
    stem = Path(path).stem.split(" (")[0]
    return stem if len(stem) <= limit else stem[:limit] + "…"


def pages_text(pages: list[int], verdicts: dict[int, str], limit: int = 30) -> str:
    shown = T["sep"].join(T["page"].format(page=p, verdict=T["verdicts"][verdicts[p]]) if p in verdicts else str(p)
                          for p in pages[:limit])
    return shown + (T["more"].format(count=len(pages) - limit) if len(pages) > limit else "")


def review_table(books: list[Book]) -> list[str]:
    rows = [f"| {short_name(book.path)} | {page} | {T['verdicts'][book.verdicts[page]]} | {book.notes.get(page, '')} |"
            for book in books for page in sorted(book.verdicts)]
    if not rows:
        return []
    unit = T["units"][0 if len(rows) == 1 else 1]
    summary = T["review"].format(count=len(rows), unit=unit)
    return [f"<details><summary>{summary}</summary>", "", T["review_header"], "| --- | --- | --- | --- |",
            *rows, "", "</details>", ""]


def report(books: list[Book], note: str) -> tuple[str, str]:
    status = "failure" if any(book.failed for book in books) else "success"
    lines = [T["passed"] if status == "success" else T["failed"], ""]
    if not books:
        lines.append(T["no_results"])
        return "\n".join(lines) + "\n", status
    lines += [T["header"], "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for book in books:
        name = short_name(book.path)
        if book.error:
            lines.append(f"| {name} | | | | | | | ❌ {book.error} |")
            continue
        def pair(result, original):
            return f"{original} → {result}" if book.original_found else f"{result}"
        mark = "❌" if book.failed else ("⚠️" if any(v == "missed" for v in book.verdicts.values()) else "✅")
        lines.append(f"| {name} | {pair(book.pages, book.original_pages)} | "
                     f"{pair(book.bookmarks, book.original_bookmarks)} | {book.chars:,} | {len(book.blank)} | "
                     f"{len(book.pictures)} | {len(book.suspect)} | {mark} |")
    lines.append("")
    for book in books:
        name = short_name(book.path)
        details = list(book.problems)
        if not book.original_found and not book.error:
            details.append(T["no_original"])
        if book.suspect:
            details.append(T["suspect"].format(pages=pages_text(book.suspect, book.verdicts)))
        if book.pictures:
            details.append(T["pictures"].format(pages=pages_text(book.pictures, book.verdicts)))
        missed = [p for p, v in book.verdicts.items() if v == "missed"]
        if missed:
            details.append(T["missed"].format(pages=T["sep"].join(map(str, sorted(missed)))))
        if details:
            lines.append(f"**{name}**")
            lines += [f"- {d}" for d in details]
            lines.append("")
    lines += review_table(books)
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
    parser.add_argument("--max-pages", type=int, default=20, help="0 reviews every flagged page")
    parser.add_argument("--model", default="claude-sonnet-5-5")
    parser.add_argument("--language", choices=sorted(STRINGS), default="en")
    args = parser.parse_args()
    global T
    T = STRINGS[args.language]
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
