#!/usr/bin/env python3
"""ECHO-7 Part A, Member A (name/SID pending), AI-assisted by OpenAI Codex.

Independent whole-image BFS oracle for 4-connected candidates. Hardware uses
bounded streaming unions; this model does not use union-find. Its capacity rule
counts raster provisional seeds (neither same-colour left nor above), including
seeds eventually merged. A colour with >CAP seeds invalidates the entire frame.
No frame buffer is implied for RTL: the image here is test/reference data only.
"""
from collections import deque
import argparse
import json
from pathlib import Path

MAX = 8
FIELDS = ("valid", "xmin", "xmax", "ymin", "ymax", "area", "cx", "cy")


def candidates(mask, cap=8, min_area=32):
    if not mask or not mask[0]:
        raise ValueError("nonempty rectangular mask required")
    h, w = len(mask), len(mask[0])
    if not (1 <= w <= 320 and 1 <= h <= 240 and 1 <= cap <= 8 and 1 <= min_area <= w*h):
        raise ValueError("geometry/cap/min_area outside RTL contract")
    if any(len(row) != w or any(type(p) is not int or p not in (0, 1, 2) for p in row) for row in mask):
        raise ValueError("mask must be rectangular integers 0,1,2")
    seeds = {colour: sum(mask[y][x] == colour and (x == 0 or mask[y][x-1] != colour)
                       and (y == 0 or mask[y-1][x] != colour) for y in range(h) for x in range(w))
             for colour in (1, 2)}
    seen = [[False] * w for _ in range(h)]
    found = {1: [], 2: []}
    for y in range(h):
        for x in range(w):
            colour = mask[y][x]
            if colour == 0 or seen[y][x]:
                continue
            seen[y][x] = True
            queue = deque([(x, y)])
            area, xmin, xmax, ymin, ymax = 0, x, x, y, y
            while queue:
                xx, yy = queue.popleft()
                area += 1
                xmin, xmax, ymin, ymax = min(xmin, xx), max(xmax, xx), min(ymin, yy), max(ymax, yy)
                for nx, ny in ((xx-1, yy), (xx+1, yy), (xx, yy-1), (xx, yy+1)):
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and mask[ny][nx] == colour:
                        seen[ny][nx] = True
                        queue.append((nx, ny))
            if area >= min_area:
                found[colour].append(dict(valid=1, xmin=xmin, xmax=xmax, ymin=ymin, ymax=ymax,
                                          area=area, cx=(xmin+xmax)//2, cy=(ymin+ymax)//2))
    red_overflow, blue_overflow = seeds[1] > cap, seeds[2] > cap
    valid = not (red_overflow or blue_overflow)
    # Suppress all results on overflow. Internal hardware diagnostic boxes are not an oracle contract.
    return dict(frame_valid=valid, red_overflow=red_overflow, blue_overflow=blue_overflow,
                overflow=not valid, provisional_red=seeds[1], provisional_blue=seeds[2],
                red=found[1] if valid else [], blue=found[2] if valid else [])


def vector_cases(w=320, h=240):
    def blank(): return [[0] * w for _ in range(h)]
    def rect(a, colour, x0, y0, x1, y1):
        for yy in range(y0, y1+1):
            for xx in range(x0, x1+1): a[yy][xx] = colour
    result = []
    a = blank()
    rect(a,1,2,2,5,4); rect(a,1,12,3,15,6); rect(a,2,25,2,28,6); rect(a,2,40,8,42,10)
    result.append(("separated_two_each_colour", a))
    a=blank();rect(a,1,2,2,4,4);rect(a,1,5,3,7,5);rect(a,2,30,30,32,32);rect(a,2,31,33,33,35)
    result.append(("touching_edges_merge",a))
    a=blank();rect(a,1,2,2,3,3);rect(a,1,4,4,5,5)
    result.append(("diagonal_contact_stays_separate",a))
    a=blank();rect(a,1,2,2,2,12);rect(a,1,10,2,10,12);rect(a,1,2,12,10,12)
    result.append(("late_u_union",a))
    a=blank();rect(a,2,10,10,12,11)
    for x,y in ((1,1),(20,2),(22,3),(24,4)): a[y][x]=1
    result.append(("minimum_area_filters_noise",a))
    a=blank();rect(a,1,0,0,2,0);rect(a,2,w-3,h-1,w-1,h-1)
    result.append(("first_last_pixels_and_edges",a))
    result.append(("all_red", [[1]*w for _ in range(h)]))
    result.append(("all_blue", [[2]*w for _ in range(h)]))
    a=[[1 if (x+y)%2 == 0 else 2 for x in range(w)] for y in range(h)]
    result.append(("both_colours_capacity_overflow",a))
    a=blank()
    for x in range(2,20,2): rect(a,1,x,2,x,12)
    rect(a,1,2,12,18,12);rect(a,2,40,20,42,22)
    result.append(("nine_seeds_later_one_blob_whole_frame_invalid",a))
    a=blank()
    for x in range(2,18,2): rect(a,2,x,2,x,12)
    rect(a,2,2,12,16,12)
    result.append(("exactly_eight_seeds_later_one_blob",a))
    result.append(("empty",blank()))
    return result


def write_vectors(out):
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    cases = vector_cases()
    with (out/"masks.hex").open("w") as masks, (out/"expected.hex").open("w") as expected:
        descriptions=[]
        for name, mask in cases:
            result=candidates(mask,cap=8,min_area=3)
            masks.write("".join(f"{p:x}\n" for row in mask for p in row))
            words=[int(result["frame_valid"]),len(result["red"]),len(result["blue"]),
                   int(result["red_overflow"]),int(result["blue_overflow"]),int(result["overflow"])]
            for colour in ("red","blue"):
                for i in range(MAX):
                    c=result[colour][i] if i<len(result[colour]) else {}
                    words.extend(int(c.get(field,0)) for field in FIELDS)
            expected.write("".join(f"{word:08x}\n" for word in words))
            descriptions.append({"name":name,**result})
    metadata={"width":320,"height":240,"cap":8,"min_area":3,"case_count":len(cases),
              "expected_words_per_case":6+16*len(FIELDS),"candidate_word_order":FIELDS,
              "case_results":descriptions,"scope":"Python BFS reference vectors; RTL not executed by this command"}
    (out/"metadata.json").write_text(json.dumps(metadata,indent=2)+"\n")
    return metadata


if __name__ == "__main__":
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write-vectors",type=Path,required=True)
    args=ap.parse_args()
    metadata=write_vectors(args.write_vectors)
    print(f"Wrote {metadata['case_count']} BFS cases to {args.write_vectors}; no RTL simulation performed")
