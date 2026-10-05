"""Remove the boxes that OCRmyPDF-AppleOCR 0.4.0 strokes around every text line.

The plugin leaves a debugging switch on, so each line of the invisible text
layer comes with a red outline. This drops the drawing instructions from the
text layers and leaves everything else in the file untouched.

Usage: python strip_boxes.py <pdf>   (edited in place)
"""

import sys

import pikepdf

DRAWING = {"RG", "w", "m", "l", "h", "re", "S"}

path = sys.argv[1]
with pikepdf.open(path, allow_overwriting_input=True) as pdf:
    changed = False
    for page in pdf.pages:
        for name, layer in (page.resources.get("/XObject") or {}).items():
            if not str(name).startswith("/OCR-"):
                continue
            instructions = pikepdf.parse_content_stream(layer)
            kept = [i for i in instructions if str(i.operator) not in DRAWING]
            if len(kept) != len(instructions):
                layer.write(pikepdf.unparse_content_stream(kept))
                changed = True
    if changed:
        pdf.save(path)
