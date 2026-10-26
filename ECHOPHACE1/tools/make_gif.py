#!/usr/bin/env python3
"""make_gif.py out.gif frame_1.png frame_2.png ... : an animated GIF of the monitor frames (Pillow),
0.2 s a frame: quick enough to see the picture move, slow enough to see each frame."""
import sys
try:
    from PIL import Image
except ImportError:
    sys.exit("make_gif.py: no GIF made: it needs the Python package Pillow (pip install pillow)")
MS_PER_FRAME = 200
if len(sys.argv) < 3:
    print(__doc__); sys.exit(1)
out, files = sys.argv[1], sys.argv[2:]
files = sorted(files, key=lambda f: int("".join(c for c in f.rsplit("_", 1)[-1] if c.isdigit()) or 0))
frames = [Image.open(f).convert("P", palette=Image.ADAPTIVE, colors=128) for f in files]
frames[0].save(out, save_all=True, append_images=frames[1:], duration=MS_PER_FRAME, loop=0)
print(f"wrote {out}: {len(frames)} frames, {frames[0].size[0]}x{frames[0].size[1]}, {MS_PER_FRAME / 1000:g} s a frame")
