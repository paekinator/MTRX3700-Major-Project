#!/usr/bin/env python3
"""Build EPA2 simulation vectors from CRC-valid REAL recorded RGB565 inputs.

Expected outputs are software predictions from independent whole-image math and
the V2 bipartite-prefix BFS model, not copied measured FPGA output. Original
captures may be EPA1. This does not create or claim a measured EPA2 capture.
"""
from pathlib import Path
import argparse
import binascii
import hashlib
import json
import struct
import sys
import numpy as np

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'tools/part_a'))
from analyse_capture import classify, cleanup, centroid
from candidates_reclaimed_model import candidates_reclaimed

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected_packet(rgb, mode, sequence, red_min, blue_min):
    mask = classify(rgb,ratio_red_min=red_min,ratio_blue_min=blue_min,
                    ratio_num=3,ratio_den=2)[{0:'fixed',1:'ratio',2:'hsv',3:'fixed'}[mode]]
    regions = candidates_reclaimed(cleanup(mask).tolist(),cap=8,min_area=32)
    raw_r,raw_b=centroid(mask,1),centroid(mask,2)
    flags = 0x801f | (int(regions['frame_valid'])<<7) | (int(regions['overflow'])<<10)
    flags |= int(regions['red_overflow'])<<11 | int(regions['blue_overflow'])<<12
    flags |= int(raw_r['valid'])<<13 | int(raw_b['valid'])<<14
    words=[0]*78
    words[:13]=[0x45504132,2,sequence,sequence,sequence,flags,(320<<16)|240,
                (32<<8)|(8<<4)|mode,raw_r['area'],(raw_r['cx']<<16)|raw_r['cy'],
                raw_b['area'],(raw_b['cx']<<16)|raw_b['cy'],
                len(regions['red'])|(len(regions['blue'])<<4)]
    words[77]=(red_min<<24)|(blue_min<<16)|(3<<8)|2
    for colour,first in [('red',13),('blue',45)]:
        for i,candidate in enumerate(regions[colour]):
            words[first+4*i:first+4*i+4]=[
                (1<<31)|candidate['area'],(candidate['xmin']<<16)|candidate['xmax'],
                (candidate['ymin']<<16)|candidate['ymax'],(candidate['cx']<<16)|candidate['cy']]
    return words,dict(raw_red=raw_r,raw_blue=raw_b,candidates=regions)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',required=True,type=Path)
    parser.add_argument('--red-min',type=int,default=64)
    parser.add_argument('--blue-min',type=int,default=32)
    parser.add_argument('--captures',nargs='+',type=Path,required=True,
                        help='explicit folders containing CRC-valid dump.bin and matching frame.hex')
    parser.add_argument('--modes',nargs='+',type=int,choices=[0,1,2,3],required=True,
                        help='new replay mode per capture: 0 Fixed, 1 Ratio, 2 HSV, 3 Fixed fallback; old packet metadata is ignored')
    args=parser.parse_args()
    if not (0<=args.red_min<=255 and 0<=args.blue_min<=255):
        parser.error('thresholds must fit unsigned bytes')
    if len(args.captures)!=len(args.modes):
        parser.error('--modes must contain exactly one mode for each --captures folder')
    if args.out.exists():
        parser.error('output directory already exists; choose a fresh output folder')
    frames=[];expectations=[];modes=[];records=[]
    for sequence,(folder,mode) in enumerate(zip(args.captures,args.modes),1):
        directory=folder.resolve()
        data=(directory/'dump.bin').read_bytes()
        if len(data)<16: raise ValueError(f'{directory}: truncated snapshot')
        magic,version,width,height,fmt,count=struct.unpack_from('>4sHHHHH',data)
        if (magic,version,width,height,fmt)!=(b'GRAB',1,320,240,1):
            raise ValueError(f'{directory}: requires native GRABv1 320x240 RGB565')
        if count not in (77,78):
            raise ValueError(f'{directory}: requires a Part A transport record, not the five-word course example')
        if len(data)!=14+count*4+width*height*2+2:
            raise ValueError(f'{directory}: snapshot length mismatch')
        if binascii.crc_hqx(data[:-2],0xffff)!=int.from_bytes(data[-2:],'big'):
            raise ValueError(f'{directory}: snapshot CRC mismatch')
        # Existing result words are intentionally NOT used to form predictions.
        # Only transport count determines the pixel byte offset in dump.bin.
        px=np.frombuffer(data,dtype='>u2',offset=14+count*4,count=width*height).astype(np.uint16).reshape(height,width)
        saved=np.array([int(x,16) for x in (directory/'frame.hex').read_text().split()],dtype=np.uint16).reshape(height,width)
        if not np.array_equal(px,saved):
            raise ValueError(f'{directory}: frame.hex disagrees with CRC-checked dump pixels')
        r=(px>>11)&31;g=(px>>5)&63;b=px&31
        rgb=np.stack(((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2)),axis=2).astype(np.uint8)
        words,prediction=expected_packet(rgb,mode,sequence,args.red_min,args.blue_min)
        frames.extend(int(p) for p in px.ravel());expectations.extend(words);modes.append(mode)
        records.append(dict(name=directory.name,path=str(directory),mode=mode,replay_sequence_id=sequence,
            original_transport_result_count=count,old_result_metadata_used_for_predictions=False,
            dump_sha256=sha(directory/'dump.bin'),frame_hex_sha256=sha(directory/'frame.hex'),
            original_crc_valid=True,prediction=prediction))
        print(directory.name,'mode',mode,'rawR/B',prediction['raw_red']['area'],prediction['raw_blue']['area'],
              'V2valid',prediction['candidates']['frame_valid'],'candidatesR/B',
              len(prediction['candidates']['red']),len(prediction['candidates']['blue']))
    args.out.mkdir(parents=True,exist_ok=False)
    (args.out/'frames.hex').write_text(''.join(f'{p:04x}\n' for p in frames))
    (args.out/'expected.hex').write_text(''.join(f'{p:08x}\n' for p in expectations))
    (args.out/'modes.hex').write_text(''.join(f'{p:x}\n' for p in modes))
    metadata=dict(kind='PREDICTED EPA2 for recorded inputs; NOT measured V2 hardware outputs',
        n_cases=len(records),n_results=78,width=320,height=240,red_min=args.red_min,blue_min=args.blue_min,
        ratio_num=3,ratio_den=2,cap=8,min_area=32,cases=records,
        candidate_comparison='unordered valid descriptor multisets; invalid slot diagnostic fields unspecified',
        model_sources={str(REPO/'tools/part_a'/n):sha(REPO/'tools/part_a'/n) for n in [
            'analyse_capture.py','candidates_reclaimed_model.py','export_recorded_replay.py']})
    (args.out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print('WROTE',args.out)


if __name__=='__main__':
    try:main()
    except (OSError,ValueError,struct.error) as error:
        raise SystemExit(f'FAIL export_recorded_replay: {error}')
