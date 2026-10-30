#!/usr/bin/env python3
"""Compare ECHO Part A measured packet with an independent whole-image model.

Supports EPA1/77 words and EPA2/78 words with row-reclaimed labels. Five-word course
example/calibration capture is deliberately rejected as self-designed-module proof.
"""
import argparse
import binascii
import hashlib
import json
from pathlib import Path
import struct
import numpy as np
from PIL import Image, ImageDraw
from analyse_capture import classify, cleanup, centroid
from candidates_model import candidates


def unpack_dump(path):
    data=Path(path).read_bytes()
    if len(data)<16: raise ValueError('truncated snapshot')
    magic,version,w,h,fmt,n=struct.unpack_from('>4sHHHHH',data)
    if (magic,version,w,h,fmt)!=(b'GRAB',1,320,240,1) or n not in (77,78):
        raise ValueError('requires native 320x240 RGB565 EPA1/77-word or EPA2/78-word snapshot')
    if len(data)!=14+4*n+2*w*h+2: raise ValueError('snapshot length mismatch')
    sent=int.from_bytes(data[-2:],'big');calculated=binascii.crc_hqx(data[:-2],0xffff)
    if sent!=calculated: raise ValueError('snapshot CRC mismatch')
    words=list(struct.unpack_from(f'>{n}I',data,14))
    if (n,words[0],words[1]) not in ((77,0x45504131,1),(78,0x45504132,2)):
        raise ValueError('result count/magic/schema combination is not a supported Part A profile')
    px=np.frombuffer(data,dtype='>u2',count=w*h,offset=14+4*n).reshape(h,w)
    r=(px>>11)&31;g=(px>>5)&63;b=px&31
    rgb=np.stack(((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2)),axis=2).astype(np.uint8)
    return data,words,rgb,calculated


def check(path):
    data,words,rgb,crc=unpack_dump(path)
    comparisons=[]
    def equal(name,actual,expected):
        comparisons.append(dict(name=name,actual=actual,expected=expected,match=actual==expected))
    schema=words[1]
    equal('packet magic',words[0],0x45504131 if schema==1 else 0x45504132)
    equal('schema version',schema,1 if len(words)==77 else 2)
    equal('geometry',words[6],(320<<16)|240)
    config=words[7];mode=config&3;cap=(config>>4)&15;min_area=(config>>8)&0x1ffff
    equal('CAP',cap,8);equal('MIN_AREA',min_area,32)
    equal('configuration reserved bits',config&0xfe00000c,0)
    flags=words[5]
    for name,bit in [('same-frame association',0),('raw available',1),('candidates available',2),
                     ('IDs match flag',3),('raw frame valid',4),('native SOP seen',15)]:
        equal(name,(flags>>bit)&1,1)
    equal('raw frame error',(flags>>5)&1,0);equal('raw overrun',(flags>>6)&1,0)
    equal('candidate frame error',(flags>>8)&1,0);equal('candidate overrun',(flags>>9)&1,0)
    equal('raw busy at boundary',(flags>>16)&1,0);equal('candidate busy at boundary',(flags>>17)&1,0)
    equal('flag reserved bits',flags>>18,0)
    equal('raw frame ID',words[3],words[2]);equal('candidate frame ID',words[4],words[2])
    equal('ID upper bits',words[2]>>16,0)
    ratio_profile={}
    if schema==2:
        metadata=words[77]
        ratio_profile=dict(ratio_red_min=(metadata>>24)&255,ratio_blue_min=(metadata>>16)&255,
                           ratio_num=(metadata>>8)&255,ratio_den=metadata&255)
        if ratio_profile['ratio_num']==0 or ratio_profile['ratio_den']==0:
            raise ValueError('ratio metadata numerator and denominator must be nonzero')
    mask=classify(rgb,**ratio_profile)[{0:'fixed',1:'ratio',2:'hsv',3:'fixed'}[mode]]
    if schema==1:model=candidates(cleanup(mask).tolist(),cap=8,min_area=32)
    else:
        from candidates_reclaimed_model import candidates_reclaimed
        model=candidates_reclaimed(cleanup(mask).tolist(),cap=8,min_area=32)
    equal('candidate frame valid',(flags>>7)&1,int(model['frame_valid']))
    for name,bit in [('overflow',10),('red_overflow',11),('blue_overflow',12)]:
        equal('candidate '+name,(flags>>bit)&1,int(model[name]))
    for colour,label,area_word,centre_word,valid_bit,first in ((1,'red',8,9,13,13),(2,'blue',10,11,14,45)):
        base=centroid(mask,colour)
        equal(label+' raw area',words[area_word],base['area'])
        equal(label+' raw centroid',words[centre_word],(base['cx']<<16)|base['cy'])
        equal(label+' raw valid',(flags>>valid_bit)&1,int(base['valid']))
        found=model[label]
        count=(words[12]>>(0 if colour==1 else 4))&15
        equal(label+' candidate count',count,len(found))
        measured=[]
        for i in range(8):
            at=first+i*4;valid=words[at]>>31
            equal(f'{label}[{i}] valid',valid,int(i<len(found)))
            equal(f'{label}[{i}] reserved',(words[at]>>17)&0x3fff,0)
            if schema==2 and valid:
                measured.append(dict(valid=1,area=words[at]&0x1ffff,
                    xmin=words[at+1]>>16,xmax=words[at+1]&0xffff,
                    ymin=words[at+2]>>16,ymax=words[at+2]&0xffff,
                    cx=words[at+3]>>16,cy=words[at+3]&0xffff))
            if schema==1 and i<len(found):
                c=found[i]
                equal(f'{label}[{i}] area',words[at]&0x1ffff,c['area'])
                for field,a,b,off in [('bounds x','xmin','xmax',1),('bounds y','ymin','ymax',2),('bbox centre','cx','cy',3)]:
                    equal(f'{label}[{i}] '+field,words[at+off],(c[a]<<16)|c[b])
        if schema==2:
            order=lambda c:(c['ymin'],c['xmin'],c['ymax'],c['xmax'],c['area'],c['cx'],c['cy'])
            equal(label+' complete component descriptors (order independent)',
                  sorted(measured,key=order),sorted(found,key=order))
    equal('candidate count reserved',words[12]>>8,0)
    return dict(status='PASS' if all(c['match'] for c in comparisons) else 'FAIL',
                scope='CRC-valid same-frame measured FPGA cleanup/candidates/raw-centroid vs whole-image golden',
                source=str(Path(path).resolve()),dump_sha256=hashlib.sha256(data).hexdigest(),
                crc=f'0x{crc:04x}',frame_id=words[2],mode=mode,schema_version=schema,
                ratio_profile=ratio_profile or dict(ratio_red_min=80,ratio_blue_min=80,ratio_num=3,ratio_den=2),
                golden_candidates=model,comparisons=comparisons,
                limitation='Numerical replay verifies processing, not physical marker identity or detection accuracy.')


def measured_view(path, output, status):
    """Diagnostic plot from measured FPGA fields, never model-predicted boxes."""
    _,words,rgb,_=unpack_dump(path)
    view=Image.fromarray(rgb);draw=ImageDraw.Draw(view)
    for label,first,colour in [('R',13,'#ff5050'),('B',45,'#50a0ff')]:
        for i in range(8):
            at=first+4*i
            if not words[at]>>31:continue
            x0,x1=words[at+1]>>16,words[at+1]&0xffff
            y0,y1=words[at+2]>>16,words[at+2]&0xffff
            # A malformed measurement is reported by the checker; plot only
            # in-range rectangles so even failed captures remain inspectable.
            if 0<=x0<=x1<320 and 0<=y0<=y1<240:
                draw.rectangle((x0,y0,x1,y1),outline=colour,width=1)
                draw.text((x0,max(0,y0-11)),f'{label}{i}: {words[at]&0x1ffff}',fill=colour)
    for bit,at,colour in [(13,9,'#ff5050'),(14,11,'#50a0ff')]:
        if words[5]&(1<<bit):
            x,y=words[at]>>16,words[at]&0xffff
            if x<320 and y<240:
                draw.line((x-3,y,x+3,y),fill=colour);draw.line((x,y-3,x,y+3),fill=colour)
    canvas=Image.new('RGB',(640,510),'#20252b')
    canvas.paste(view.resize((640,480),Image.Resampling.NEAREST),(0,30))
    ImageDraw.Draw(canvas).text((8,9),f'Measured FPGA boxes / raw centroids | frame {words[2]} | golden {status}',fill='white')
    canvas.save(output)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('capture',type=Path);ap.add_argument('--output',type=Path)
    a=ap.parse_args();path=a.capture/'dump.bin' if a.capture.is_dir() else a.capture
    output=a.output or path.parent/'part-a-hardware-check.json'
    try: report=check(path)
    except (ValueError,OSError,struct.error) as error:
        report=dict(status='FAIL',scope='Part A v1 measured-packet check',error=str(error))
    output.write_text(json.dumps(report,indent=2)+'\n')
    if 'comparisons' in report:
        measured_view(path,output.parent/'measured-candidates.png',report['status'])
    print(report['status'],output)
    for item in report.get('comparisons',[]):
        if not item['match']: print('FAIL',item['name'],item['actual'],'expected',item['expected'])
    if 'error' in report:print(report['error'])
    return 0 if report['status']=='PASS' else 1


if __name__=='__main__':raise SystemExit(main())
