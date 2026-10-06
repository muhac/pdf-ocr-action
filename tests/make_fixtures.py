"""Regenerate the image-only test PDFs in tests/fixtures (macOS only, needs system fonts).

Usage: uv run --with pillow tests/make_fixtures.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FIXTURES = Path(__file__).parent / "fixtures"
DPI = 150
PAGE = (1240, 1754)  # A4 at 150 dpi

PAGES = {
    "english.pdf": (
        "/System/Library/Fonts/Helvetica.ttc",
        [
            "PDF OCR Action",
            "The quick brown fox jumps over the lazy dog.",
            "Scanned pages become searchable text.",
            "Reference number 20481.",
        ],
    ),
    "chinese.pdf": (
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        [
            "文字识别测试页面",
            "扫描版文档可以变成可搜索的文档。",
            "今天天气很好，我们一起去公园散步。",
            "本页包含 English words 和数字 20481。",
        ],
    ),
    "traditional.pdf": (
        "/System/Library/Fonts/STHeiti Medium.ttc",
        [
            "繁體中文測試頁面",
            "掃描版文件可以變成可搜尋的文件。",
            "今天天氣很好，我們一起去公園散步。",
        ],
    ),
}


def render(font_path: str, lines: list[str]) -> Image.Image:
    page = Image.new("L", PAGE, 255)
    draw = ImageDraw.Draw(page)
    font = ImageFont.truetype(font_path, 44)
    for i, line in enumerate(lines):
        draw.text((120, 160 + i * 110), line, font=font, fill=0)
    return page


SENTENCES = [
    "The quick brown fox jumps over the lazy dog near the river bank.",
    "Scanned pages become searchable text once a text layer is added.",
    "Every line on this page is ordinary printed text for the checker.",
    "A careful reader notices when a page suddenly loses its words.",
]


def text_page() -> Image.Image:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 36)
    page = Image.new("L", PAGE, 255)
    draw = ImageDraw.Draw(page)
    for i in range(24):
        draw.text((100, 120 + i * 62), SENTENCES[i % len(SENTENCES)], font=font, fill=0)
    return page


def illustration_page() -> Image.Image:
    page = Image.new("L", PAGE, 255)
    draw = ImageDraw.Draw(page)
    draw.ellipse((200, 300, 700, 800), fill=90)
    draw.rectangle((600, 700, 1050, 1150), fill=150, outline=0, width=8)
    draw.polygon([(150, 1500), (550, 1000), (950, 1500)], fill=40)
    return page


def check_pages() -> list[Image.Image]:
    """A text page, a blank page and an illustration: what the OCR check has to tell apart."""
    return [text_page(), Image.new("L", PAGE, 255), illustration_page()]


if __name__ == "__main__":
    FIXTURES.mkdir(exist_ok=True)
    for name, (font_path, lines) in PAGES.items():
        render(font_path, lines).save(FIXTURES / name, "PDF", resolution=DPI)
        print(f"wrote {FIXTURES / name}")
    first, *rest = check_pages()
    first.save(FIXTURES / "pages.pdf", "PDF", resolution=DPI, save_all=True, append_images=rest)
    print(f"wrote {FIXTURES / 'pages.pdf'} (run scripts/ocr.sh on it to refresh pages.ocr.pdf)")
