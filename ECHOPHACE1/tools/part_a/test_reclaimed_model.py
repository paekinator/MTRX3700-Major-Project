"""Independent whole-prefix BFS checks for V2 row-graph reclamation model.

ECHO-7 Member A (name/SID pending), AI-assisted by OpenAI Codex.
"""
from collections import deque
import random
import unittest

from candidates_reclaimed_model import candidates_reclaimed, vector_cases


def full_bfs(mask, colour):
    """Unbounded whole-image pixel flood fill, independent of row-run graph."""
    h, w = len(mask), len(mask[0])
    seen = set()
    components = []
    for y in range(h):
        for x in range(w):
            if mask[y][x] != colour or (x, y) in seen:
                continue
            queue = deque([(x, y)])
            seen.add((x, y))
            points = []
            while queue:
                xx, yy = queue.popleft()
                points.append((xx, yy))
                for nx, ny in ((xx-1, yy), (xx+1, yy), (xx, yy-1), (xx, yy+1)):
                    if 0 <= nx < w and 0 <= ny < h and mask[ny][nx] == colour and (nx, ny) not in seen:
                        seen.add((nx, ny))
                        queue.append((nx, ny))
            xs, ys = zip(*points)
            components.append(dict(points=points, xmin=min(xs), xmax=max(xs), ymin=min(ys), ymax=max(ys),
                                   area=len(points), cx=(min(xs)+max(xs))//2, cy=(min(ys)+max(ys))//2, valid=1))
    return components


def descriptor_set(components):
    return sorted(tuple(c[f] for f in ("xmin", "xmax", "ymin", "ymax", "area", "cx", "cy")) for c in components)


class ReclaimedModelTests(unittest.TestCase):
    def test_diagonal_is_not_four_connected(self):
        result = candidates_reclaimed([[1, 0], [0, 1]], min_area=1)
        self.assertEqual(len(result["red"]), 2)

    def test_late_merge_exact_area_bounds_and_bbox_midpoint(self):
        result = candidates_reclaimed([[1,0,0,1], [1,0,0,1], [1,1,1,1]], min_area=1)
        self.assertEqual(result["red"], [dict(valid=1, xmin=0, xmax=3, ymin=0, ymax=2, area=8, cx=1, cy=1)])

    def test_serial_subminimum_noise_does_not_fill_completed_pool(self):
        mask = [[0]*8 for _ in range(80)]
        for y in range(0, 50, 2):
            mask[y][0] = 1
        for y in range(60, 64):
            mask[y] = [1]*8
        result = candidates_reclaimed(mask, min_area=32)
        self.assertTrue(result["frame_valid"])
        self.assertEqual(result["red_lifetime_seeds"], 26)
        self.assertEqual(result["red_qualifying_completed"], 1)
        self.assertEqual(result["red"][0]["area"], 32)

    def test_aliases_reclaimed_after_late_union(self):
        _, mask = vector_cases()[13]
        result = candidates_reclaimed(mask, min_area=3)
        self.assertTrue(result["frame_valid"])
        self.assertEqual(result["red_lifetime_seeds"], 15)
        self.assertEqual(result["red_max_row_handles"], 8)
        self.assertEqual(len(result["red"]), 2)
        self.assertEqual(descriptor_set(result["red"]), descriptor_set(full_bfs(mask, 1)))

    def test_nine_serial_valid_components_overflow_completed_pool_only(self):
        _, mask = vector_cases()[14]
        result = candidates_reclaimed(mask, min_area=3)
        self.assertFalse(result["red_active_overflow"])
        self.assertTrue(result["red_output_overflow"])
        self.assertEqual(result["red_qualifying_completed"], 9)
        self.assertFalse(result["frame_valid"])
        self.assertEqual(result["red"], [])
        self.assertEqual(result["blue"], [])

    def test_nine_concurrent_handles_overflow_even_when_eventually_one_blob(self):
        _, mask = vector_cases()[15]
        result = candidates_reclaimed(mask, min_area=3)
        self.assertTrue(result["blue_active_overflow"])
        self.assertFalse(result["blue_output_overflow"])
        self.assertEqual(result["blue_qualifying_completed"], 1)

    def test_exactly_eight_completed_per_colour_is_valid(self):
        _, mask = vector_cases()[16]
        result = candidates_reclaimed(mask, min_area=3)
        self.assertTrue(result["frame_valid"])
        self.assertEqual((len(result["red"]), len(result["blue"])), (8, 8))

    def test_absent_old_roots_not_reused_before_row_seal(self):
        _, mask = vector_cases()[17]
        result = candidates_reclaimed(mask, min_area=3)
        self.assertTrue(result["red_active_overflow"])
        self.assertFalse(result["red_output_overflow"])
        self.assertEqual(result["red_max_row_handles"], 9)

    def test_native_all_foreground_exact_area_and_final_row_retirement(self):
        result = candidates_reclaimed([[2]*320 for _ in range(240)])
        self.assertTrue(result["frame_valid"])
        self.assertEqual(result["blue"], [dict(valid=1, xmin=0, xmax=319, ymin=0, ymax=239, area=76800, cx=159, cy=119)])

    def test_empty_and_single_pixel_border(self):
        self.assertEqual(candidates_reclaimed([[0]], min_area=1)["red"], [])
        self.assertEqual(candidates_reclaimed([[1]], min_area=1)["red"][0]["area"], 1)

    def test_invalid_input_rejected(self):
        for mask in ([], [[]], [[1, 2], [1]], [[3]], [[True]], [["1"]]):
            with self.assertRaises(ValueError):
                candidates_reclaimed(mask, min_area=1)

    def test_random_small_frames_against_independent_whole_prefix_bfs(self):
        rng = random.Random(3700)
        for trial in range(80):
            mask = [[rng.choice([0, 0, 0, 1, 2]) for _ in range(9)] for _ in range(6)]
            cap = (1, 2, 4, 8)[trial % 4]
            minimum = (1, 2, 3)[trial % 3]
            expected = {}
            for colour, name in ((1, "red"), (2, "blue")):
                peak = 0
                for y in range(len(mask)):
                    # Re-flood every full prefix rather than using incremental summaries.
                    carry = sum(any(py == y-1 for _, py in c["points"]) for c in full_bfs(mask[:y], colour)) if y else 0
                    seeds = sum(mask[y][x] == colour and (x == 0 or mask[y][x-1] != colour) and
                                (y == 0 or mask[y-1][x] != colour) for x in range(9))
                    peak = max(peak, carry+seeds)
                components = [c for c in full_bfs(mask, colour) if c["area"] >= minimum]
                expected[name] = dict(peak=peak, active=peak>cap, output=len(components)>cap, components=components)
            result = candidates_reclaimed(mask, cap=cap, min_area=minimum)
            valid = not any(e["active"] or e["output"] for e in expected.values())
            self.assertEqual(result["frame_valid"], valid, f"trial {trial}")
            for name, e in expected.items():
                self.assertEqual(result[name+"_active_overflow"], e["active"], f"trial {trial}/{name}")
                self.assertEqual(result[name+"_output_overflow"], e["output"], f"trial {trial}/{name}")
                self.assertEqual(result[name+"_max_row_handles"], e["peak"], f"trial {trial}/{name}")
                self.assertEqual(descriptor_set(result[name]), descriptor_set(e["components"]) if valid else [])


if __name__ == "__main__":
    unittest.main()
