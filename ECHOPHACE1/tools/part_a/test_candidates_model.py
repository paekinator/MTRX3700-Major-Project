"""ECHO-7 Part A, Member A (SID pending); AI-assisted meaningful BFS oracle tests."""
import unittest
from candidates_model import candidates, vector_cases


class CandidateModelTests(unittest.TestCase):
    def test_diagonal_is_not_four_connected(self):
        r=candidates([[1,0],[0,1]],min_area=1)
        self.assertEqual(len(r['red']),2)

    def test_late_merge_combines_area_bounds_exactly(self):
        r=candidates([[1,0,0,1],[1,0,0,1],[1,1,1,1]],min_area=1)
        self.assertEqual(r['provisional_red'],2)
        self.assertEqual(r['red'],[dict(valid=1,xmin=0,xmax=3,ymin=0,ymax=2,area=8,cx=1,cy=1)])

    def test_bbox_midpoint_not_centroid(self):
        r=candidates([[1,1,1,1],[1,0,0,0],[1,0,0,0]],min_area=1)
        c=r['red'][0]
        self.assertEqual((c['cx'],c['cy']),(1,1))
        self.assertNotEqual(c['cy'],(0+0+0+0+1+2)//6)

    def test_capacity_counts_provisional_not_final_blobs(self):
        r=candidates([[1,0,1,0,1],[1,1,1,1,1]],cap=2,min_area=1)
        self.assertEqual(r['provisional_red'],3)
        self.assertTrue(r['red_overflow'])
        self.assertFalse(r['frame_valid'])
        self.assertEqual(r['red'],[])

    def test_one_colour_overflow_suppresses_other_colour(self):
        r=candidates([[1,0,1,0,2],[0,0,0,0,2]],cap=1,min_area=1)
        self.assertTrue(r['red_overflow']); self.assertFalse(r['blue_overflow'])
        self.assertEqual(r['blue'],[])

    def test_min_area_is_after_union(self):
        r=candidates([[1,0,1],[1,1,1]],min_area=5)
        self.assertEqual(r['red'][0]['area'],5)
        self.assertEqual(candidates([[1,0,1],[1,1,1]],min_area=6)['red'],[])

    def test_full_native_frame_area_and_width(self):
        r=candidates([[2]*320 for _ in range(240)],min_area=32)
        self.assertEqual(r['blue'],[dict(valid=1,xmin=0,xmax=319,ymin=0,ymax=239,area=76800,cx=159,cy=119)])

    def test_empty_and_exact_capacity(self):
        self.assertTrue(candidates([[0]*8 for _ in range(2)],min_area=1)['frame_valid'])
        r=candidates([[1,0,1,0,1,0,1]],cap=4,min_area=1)
        self.assertEqual(len(r['red']),4); self.assertFalse(r['overflow'])

    def test_vectors_cover_overflow_and_final_pixel(self):
        cases=dict(vector_cases())
        r=candidates(cases['first_last_pixels_and_edges'],min_area=3)
        self.assertEqual(r['blue'][0]['xmax'],319);self.assertEqual(r['blue'][0]['ymax'],239)
        r=candidates(cases['nine_seeds_later_one_blob_whole_frame_invalid'],min_area=3)
        self.assertTrue(r['red_overflow']);self.assertEqual(r['blue'],[])
        r=candidates(cases['exactly_eight_seeds_later_one_blob'],min_area=3)
        self.assertEqual(r['provisional_blue'],8);self.assertEqual(len(r['blue']),1)

    def test_invalid_masks_rejected(self):
        for mask in ([],[[3]],[[True]],[[1],[0,0]]):
            with self.assertRaises(ValueError): candidates(mask,min_area=1)


if __name__=='__main__': unittest.main(verbosity=2)
