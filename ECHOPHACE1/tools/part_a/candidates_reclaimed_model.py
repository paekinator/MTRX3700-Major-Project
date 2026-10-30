#!/usr/bin/env python3
"""Independent ECHO-7 V2 row-reclaimed CCL oracle; no union-find or RTL simulation.

Human owner: Member A (name/SID pending). AI-assisted by OpenAI Codex.

Each row is a bipartite graph: completed-prefix components touching the previous
row, and horizontal foreground runs in the current row. Overlapping columns add
edges. BFS of that graph computes the new prefix components and retires those
absent from the current row. This differs from RTL's per-pixel label union table.

Capacity is checked independently: carried prefix components + new raster seeds
in this row must not exceed CAP, even if merges later free aliases. No handle is
reused until row sealing. Retired components below MIN_AREA consume no output
slot; at most CAP qualifying completed components per colour can be published.
The final row retires everything. Either overflow invalidates the whole frame.

After an active overflow this oracle continues an unbounded graph for diagnostic
counts. Such continuation is not a promise about discarded RTL descriptors.
"""
from collections import deque
import argparse
import json
from pathlib import Path

from candidates_model import FIELDS, vector_cases as legacy_vector_cases


def _box(xmin, xmax, ymin, ymax, area):
    return dict(valid=1, xmin=xmin, xmax=xmax, ymin=ymin, ymax=ymax, area=area,
                cx=(xmin+xmax)//2, cy=(ymin+ymax)//2)


def _colour_rows(mask, colour, cap, minimum):
    h, w = len(mask), len(mask[0])
    previous_line = [0]*w
    active = {}  # canonical previous-prefix components, keyed by oracle-only ID
    completed = []
    completed_count = retired_count = lifetime_seeds = max_row_handles = 0
    active_overflow = output_overflow = False
    for y, row in enumerate(mask):
        runs = []
        x = 0
        while x < w:
            if row[x] != colour:
                x += 1
                continue
            x0 = x
            while x+1 < w and row[x+1] == colour:
                x += 1
            runs.append((x0, x))
            x += 1
        # Only a run's first pixel can have no same-colour left neighbour.
        seeds = sum(y == 0 or mask[y-1][x0] != colour for x0, _ in runs)
        lifetime_seeds += seeds
        handles = len(active) + seeds
        max_row_handles = max(max_row_handles, handles)
        active_overflow |= handles > cap

        old_count = len(active)
        graph = {node: set() for node in range(1, old_count+len(runs)+1)}
        run_by_node = {}
        for run_n, (x0, x1) in enumerate(runs):
            node = old_count + run_n + 1
            run_by_node[node] = (x0, x1)
            for old_node in set(previous_line[x0:x1+1]) - {0}:
                graph[node].add(old_node)
                graph[old_node].add(node)

        visited = set()
        next_active = {}
        next_line = [0]*w
        for first in graph:
            if first in visited:
                continue
            queue = deque([first])
            visited.add(first)
            members = []
            boxes = []
            current_runs = []
            while queue:
                node = queue.popleft()
                members.append(node)
                if node <= old_count:
                    boxes.append(active[node])
                else:
                    x0, x1 = run_by_node[node]
                    current_runs.append((x0, x1))
                    boxes.append(_box(x0, x1, y, y, x1-x0+1))
                for neighbour in graph[node]:
                    if neighbour not in visited:
                        visited.add(neighbour)
                        queue.append(neighbour)
            combined = _box(min(b["xmin"] for b in boxes), max(b["xmax"] for b in boxes),
                            min(b["ymin"] for b in boxes), max(b["ymax"] for b in boxes),
                            sum(b["area"] for b in boxes))
            if not current_runs or y == h-1:
                retired_count += 1
                if combined["area"] >= minimum:
                    completed_count += 1
                    if len(completed) < cap:
                        completed.append(combined)
                    else:
                        output_overflow = True
            else:
                new_id = len(next_active)+1
                next_active[new_id] = combined
                for x0, x1 in current_runs:
                    next_line[x0:x1+1] = [new_id]*(x1-x0+1)
        active, previous_line = next_active, next_line
    completed.sort(key=lambda c: tuple(c[k] for k in ("ymin", "xmin", "ymax", "xmax", "area")))
    return dict(completed=completed, active_overflow=active_overflow,
                output_overflow=output_overflow, max_row_handles=max_row_handles,
                lifetime_seeds=lifetime_seeds, qualifying_completed=completed_count,
                total_retired=retired_count)


def candidates_reclaimed(mask, cap=8, min_area=32):
    """Return exact descriptors and conservative per-row capacity results.

    Input is a rectangular list of integer rows, 0=background,1=red,2=blue.
    All valid output descriptor ordering is intentionally unspecified; compare
    multisets of (xmin,xmax,ymin,ymax,area,cx,cy), not slot order.
    """
    if not mask or not mask[0]:
        raise ValueError("nonempty rectangular mask required")
    h, w = len(mask), len(mask[0])
    if not (1 <= w <= 320 and 1 <= h <= 240 and 1 <= cap <= 8 and 1 <= min_area <= w*h):
        raise ValueError("geometry/cap/min_area outside V2 contract")
    if any(len(row) != w or any(type(p) is not int or p not in (0, 1, 2) for p in row) for row in mask):
        raise ValueError("mask must be rectangular integers0,1,2")
    results = {name: _colour_rows(mask, colour, cap, min_area) for name, colour in (("red", 1), ("blue", 2))}
    overflow = {name: r["active_overflow"] or r["output_overflow"] for name, r in results.items()}
    valid = not any(overflow.values())
    answer = dict(frame_valid=valid, overflow=not valid,
                  red_overflow=overflow["red"], blue_overflow=overflow["blue"],
                  red=results["red"]["completed"] if valid else [],
                  blue=results["blue"]["completed"] if valid else [])
    for name, r in results.items():
        for field in ("active_overflow", "output_overflow", "max_row_handles", "lifetime_seeds", "qualifying_completed", "total_retired"):
            answer[name+"_"+field] = r[field]
    return answer


def vector_cases():
    cases = legacy_vector_cases()
    def blank():
        return [[0]*320 for _ in range(240)]
    def rect(mask, colour, x0, y0, x1, y1):
        for y in range(y0, y1+1):
            mask[y][x0:x1+1] = [colour]*(x1-x0+1)
    a = blank()
    for y in range(2, 150, 3):
        a[y][10] = 1
        a[y][30:32] = [2, 2]
    rect(a, 1, 20, 200, 27, 207)
    cases.append(("serial_subminimum_noise_retires_without_output_slots", a))
    a = blank()
    for x in range(2, 18, 2):
        rect(a, 1, x, 2, x, 9)
    rect(a, 1, 2, 9, 16, 9)
    rect(a, 1, 2, 10, 2, 13)
    for x in range(40, 54, 2):
        rect(a, 1, x, 10, x, 13)
    rect(a, 1, 40, 13, 52, 13)
    cases.append(("late_union_alias_handles_reused_next_row", a))
    a = blank()
    for y in range(2, 29, 3):
        rect(a, 1, 10, y, 12, y)
    rect(a, 2, 50, 40, 52, 41)
    cases.append(("nine_serial_valid_red_output_pool_overflow", a))
    a = blank()
    for x in range(2, 20, 2):
        rect(a, 2, x, 5, x, 8)
    rect(a, 2, 2, 8, 18, 8)
    cases.append(("nine_concurrent_blue_handles_later_merge_active_overflow", a))
    a = blank()
    for i in range(8):
        rect(a, 1, 10, 5+5*i, 11, 6+5*i)
        rect(a, 2, 30, 5+5*i, 32, 6+5*i)
    cases.append(("exactly_eight_completed_per_colour", a))
    a = blank()
    for x in range(2, 18, 2):
        rect(a, 1, x, 2, x, 3)
    rect(a, 1, 30, 4, 32, 4)
    cases.append(("old_absent_roots_still_occupy_handles_until_row_seal", a))
    return cases


def write_vectors(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    descriptions = []
    with (directory / "masks.hex").open("w") as masks, (directory / "expected.hex").open("w") as expected:
        for name, mask in vector_cases():
            result = candidates_reclaimed(mask, cap=8, min_area=3)
            masks.write("".join(f"{pixel:x}\n" for row in mask for pixel in row))
            words = [int(result["frame_valid"]), len(result["red"]), len(result["blue"]),
                     int(result["red_overflow"]), int(result["blue_overflow"]), int(result["overflow"])]
            for colour in ("red", "blue"):
                for i in range(8):
                    candidate = result[colour][i] if i < len(result[colour]) else {}
                    words.extend(int(candidate.get(field, 0)) for field in FIELDS)
            expected.write("".join(f"{word:08x}\n" for word in words))
            descriptions.append({"name": name, **result})
    metadata = dict(schema="echo-candidates-row-reclaimed-v2", width=320, height=240, cap=8, min_area=3,
                    case_count=len(descriptions), expected_words_per_case=134,
                    candidate_word_order=FIELDS, compare_descriptor_order="unordered multiset",
                    case_results=descriptions,
                    scope="Independent row-graph BFS oracle vectors; this command does not execute RTL")
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2)+"\n")
    return metadata


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-vectors", type=Path, required=True)
    args = parser.parse_args()
    metadata = write_vectors(args.write_vectors)
    print(f"Wrote {metadata['case_count']} V2 BFS cases to {args.write_vectors}; no RTL simulation performed")
