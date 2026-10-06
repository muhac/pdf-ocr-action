"""Build the PDFs the check tests compare, from fixtures/pages.pdf and fixtures/pages.ocr.pdf.

Every case has ten pages: eight text pages, one blank page, one illustration.

Usage: python check_cases.py <case> <output.pdf>
  original    the scan, with two bookmarks
  result      its OCR result, with the same bookmarks
  boxed       the result with a stroke drawn in a text layer
  short       the result missing its last page
  lost        a "result" without any text (the OCR lost everything)
  unmarked    the result without its bookmarks
  half        the result without text on pages 5-8, like an OCR run that lost text
  lost30      like "lost", but with 28 text pages (30 pages in all)
"""

import sys
from pathlib import Path

import pikepdf

FIXTURES = Path(__file__).parent / "fixtures"


def ten_pages(source: Path, plain: tuple[int, ...] = (), text_pages: int = 8) -> pikepdf.Pdf:
    """Pages listed in `plain` (1-based) come from the scan, so they have no text layer."""
    ocr, scan = pikepdf.open(source), pikepdf.open(FIXTURES / "pages.pdf")
    pdf = pikepdf.new()
    for number, index in enumerate([0] * text_pages + [1, 2], 1):
        pdf.pages.append((scan if number in plain else ocr).pages[index])
    return pdf


def bookmark(pdf: pikepdf.Pdf) -> None:
    with pdf.open_outline() as outline:
        outline.root.append(pikepdf.OutlineItem("Chapter 1", 0))
        outline.root.append(pikepdf.OutlineItem("Chapter 2", 4))


case, out = sys.argv[1], sys.argv[2]
pdf = ten_pages(FIXTURES / ("pages.pdf" if case in ("original", "lost", "lost30") else "pages.ocr.pdf"),
                plain=(5, 6, 7, 8) if case == "half" else (), text_pages=28 if case == "lost30" else 8)
if case != "unmarked":
    bookmark(pdf)
if case == "boxed":
    for name, layer in pdf.pages[0].resources["/XObject"].items():
        if str(name).startswith("/OCR-"):
            layer.write(layer.read_bytes() + b"\nq 1 0 0 RG 0.75 w 10 10 m 200 10 l S Q\n")
if case == "short":
    del pdf.pages[-1]
pdf.save(out)
