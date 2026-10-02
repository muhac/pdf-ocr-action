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
}


def render(font_path: str, lines: list[str]) -> Image.Image:
    page = Image.new("L", PAGE, 255)
    draw = ImageDraw.Draw(page)
    font = ImageFont.truetype(font_path, 44)
    for i, line in enumerate(lines):
        draw.text((120, 160 + i * 110), line, font=font, fill=0)
    return page


if __name__ == "__main__":
    FIXTURES.mkdir(exist_ok=True)
    for name, (font_path, lines) in PAGES.items():
        render(font_path, lines).save(FIXTURES / name, "PDF", resolution=DPI)
        print(f"wrote {FIXTURES / name}")
