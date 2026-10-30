"""Synthetic decoder/checker tests; these are NOT FPGA measurements."""
import binascii
from pathlib import Path
import struct
import tempfile
import unittest
from check_hardware_packet import check


def fixture():
    words=[0]*77
    words[:8]=[0x45504131,1,42,42,42,0,320<<16|240,32<<8|8<<4]
    words[5]=sum(1<<i for i in (0,1,2,3,4,7,13,14,15))
    words[8:13]=[64,13<<16|23,64,103<<16|83,0x11]
    words[13:17]=[1<<31|63,10<<16|17,20<<16|27,13<<16|23]
    words[45:49]=[1<<31|63,100<<16|107,80<<16|87,103<<16|83]
    pixels=[0]*76800
    for y in range(20,28):
        for x in range(10,18):pixels[y*320+x]=0xf800
    for y in range(80,88):
        for x in range(100,108):pixels[y*320+x]=0x001f
    return words,pixels


def fixture_v2():
    """Hand-defined dim rectangles exercise R64/B32 and two red output slots.

    RGB565 0x4800 expands to (74,0,0), and 0x0005 to (0,0,41).
    Every 8x8 rectangle has 64 raw pixels and loses only its first corner
    through causal cleanup. The two red raw centroids combine to (23,33).
    No classifier, cleanup, or component-model helper supplies expectations.
    """
    words,pixels=fixture()
    words[0:2]=[0x45504132,2]
    words[7]|=1
    words[8:10]=[128,23<<16|33]
    words[12]=0x12
    words[17:21]=[1<<31|63,30<<16|37,40<<16|47,33<<16|43]
    words.append(64<<24|32<<16|3<<8|2)
    for y in range(20,28):
        for x in range(10,18):pixels[y*320+x]=0x4800
    for y in range(40,48):
        for x in range(30,38):pixels[y*320+x]=0x4800
    for y in range(80,88):
        for x in range(100,108):pixels[y*320+x]=0x0005
    return words,pixels


def encode(words,pixels):
    body=struct.pack('>4sHHHHH',b'GRAB',1,320,240,1,len(words))
    body+=struct.pack(f'>{len(words)}I',*words)+struct.pack('>76800H',*pixels)
    return body+struct.pack('>H',binascii.crc_hqx(body,0xffff))


class CheckerTests(unittest.TestCase):
    def run_fixture(self,words,pixels):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'SYNTHETIC_NOT_HARDWARE.bin'
            path.write_bytes(encode(words,pixels))
            return check(path)

    def test_hand_calculated_two_rectangles(self):
        self.assertEqual(self.run_fixture(*fixture())['status'],'PASS')

    def test_crc_valid_wrong_candidate_area_is_caught(self):
        words,pixels=fixture();words[13]+=1
        report=self.run_fixture(words,pixels)
        self.assertEqual(report['status'],'FAIL')
        self.assertTrue(any(c['name']=='red[0] area' and not c['match'] for c in report['comparisons']))

    def test_v2_hand_calculated_dim_rectangles(self):
        report=self.run_fixture(*fixture_v2())
        self.assertEqual(report['status'],'PASS')
        self.assertEqual(report['schema_version'],2)
        self.assertEqual(report['ratio_profile'],dict(ratio_red_min=64,
            ratio_blue_min=32,ratio_num=3,ratio_den=2))
        # Removing the first corner creates a new left seed on the second
        # row before it merges upward: two handles, one final component.
        self.assertEqual(report['golden_candidates']['red_max_row_handles'],2)

    def test_v2_crc_valid_wrong_threshold_metadata_is_caught(self):
        for profile,field in ((80<<24|32<<16|3<<8|2,'red raw area'),
                              (64<<24|80<<16|3<<8|2,'blue raw area')):
            with self.subTest(profile=profile):
                words,pixels=fixture_v2();words[77]=profile
                report=self.run_fixture(words,pixels)
                self.assertEqual(report['status'],'FAIL')
                self.assertTrue(any(c['name']==field and not c['match'] for c in report['comparisons']))

    def test_v2_crc_valid_wrong_candidate_is_caught(self):
        words,pixels=fixture_v2();words[13]+=1
        report=self.run_fixture(words,pixels)
        self.assertEqual(report['status'],'FAIL')
        self.assertTrue(any(c['name']=='red complete component descriptors (order independent)'
                            and not c['match'] for c in report['comparisons']))

    def test_v2_candidate_permutation_is_accepted(self):
        words,pixels=fixture_v2()
        words[13:17],words[17:21]=words[17:21],words[13:17]
        self.assertEqual(self.run_fixture(words,pixels)['status'],'PASS')

    def test_v2_duplicate_descriptor_is_caught(self):
        words,pixels=fixture_v2();words[17:21]=words[13:17]
        self.assertEqual(self.run_fixture(words,pixels)['status'],'FAIL')

    def test_frame_mismatch_is_caught(self):
        words,pixels=fixture();words[4]=41
        self.assertEqual(self.run_fixture(words,pixels)['status'],'FAIL')

    def test_course_example_is_rejected(self):
        words,pixels=fixture()
        with self.assertRaises(ValueError):self.run_fixture(words[:5],pixels)

    def test_corrupted_transport_is_rejected(self):
        words,pixels=fixture();data=bytearray(encode(words,pixels));data[1000]^=1
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'SYNTHETIC_NOT_HARDWARE.bin';path.write_bytes(data)
            with self.assertRaises(ValueError):check(path)


if __name__=='__main__':unittest.main(verbosity=2)
