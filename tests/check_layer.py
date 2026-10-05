"""Count drawing operators inside a PDF's OCR text layers (there should be none).

Usage: python check_layer.py <pdf>   -> prints "drawing_ops=<n>"
"""

import sys

import pikepdf

DRAWING = {"RG", "rg", "w", "m", "l", "h", "re", "S", "s", "f", "B"}

drawing = 0
with pikepdf.open(sys.argv[1]) as pdf:
    for page in pdf.pages:
        for name, layer in (page.resources.get("/XObject") or {}).items():
            if not str(name).startswith("/OCR-"):
                continue
            drawing += sum(1 for _, op in pikepdf.parse_content_stream(layer) if str(op) in DRAWING)
print(f"drawing_ops={drawing}")
