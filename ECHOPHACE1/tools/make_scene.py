#!/usr/bin/env python3
"""make_scene.py picture.png scene.hex [--size 656x488]

Turn any picture into what the camera model "sees": a .hex of 24-bit RGB words, row-major, one per
sensor pixel of the 656 x 488 array (the model's SCENE_FILE parameter, with SCENE_W/SCENE_H if you
choose another size). The picture is resized to fill the array. Also writes scene.png (what was
written) for checking.

    ov7670_model #(.SCENE_FILE("scene.hex")) cam (...);
"""
import sys
try:
    from PIL import Image
except ImportError:
    sys.exit("make_scene.py: it needs the Python package Pillow (pip install pillow)")
args = [a for a in sys.argv[1:] if not a.startswith("--")]
size = (656, 488)
for a in sys.argv[1:]:
    if a.startswith("--size"):
        w, h = a.split("=")[1].split("x") if "=" in a else sys.argv[sys.argv.index(a) + 1].split("x")
        size = (int(w), int(h))
if len(args) < 2:
    print(__doc__); sys.exit(1)
src, dst = args[0], args[1]
img = Image.open(src).convert("RGB").resize(size, Image.LANCZOS)
px = img.load()
with open(dst, "w") as f:
    for y in range(size[1]):
        f.write("\n".join(f"{r:02x}{g:02x}{b:02x}" for r, g, b in (px[x, y] for x in range(size[0]))) + "\n")
img.save(dst.rsplit(".", 1)[0] + ".png")
print(f"wrote {dst}: {size[0]}x{size[1]} RGB words")
