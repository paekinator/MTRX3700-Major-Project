#!/usr/bin/env python3
"""Software predictions for native RGB565 captures, NOT hardware candidate evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from candidates_model import candidates


def classify(rgb, ratio_red_min=80, ratio_blue_min=80, ratio_num=3, ratio_den=2):
    r,g,b=(rgb[:,:,i].astype(np.int64) for i in range(3))
    fixed_r=(r>=160)&(g<=100)&(b<=100)
    fixed_b=(b>=160)&(r<=100)&(g<=100)
    ratio_r=(r>=ratio_red_min)&(ratio_den*r>=ratio_num*g)&(ratio_den*r>=ratio_num*b)
    ratio_b=(b>=ratio_blue_min)&(ratio_den*b>=ratio_num*r)&(ratio_den*b>=ratio_num*g)
    mx=np.maximum(np.maximum(r,g),b);mn=np.minimum(np.minimum(r,g),b);d=mx-mn
    # Tie precedence matches hsvSeg: R, then G, then B. Hue is rational n/d.
    hue=np.where(mx==r,256*(g-b)+np.where(g<b,1536*d,0),
                 np.where(mx==g,512*d+256*(b-r),1024*d+256*(r-g)))
    chromatic=(d!=0)&(mx>=80)&(255*d>=96*mx)
    hsv_r=chromatic&((hue<=85*d)|(hue>=1451*d))
    hsv_b=chromatic&(hue>=853*d)&(hue<=1109*d)
    def pack(red,blue):
        return np.where(red^blue,np.where(red,1,2),0).astype(np.uint8)
    return dict(fixed=pack(fixed_r,fixed_b),ratio=pack(ratio_r,ratio_b),hsv=pack(hsv_r,hsv_b))


def cleanup(mask):
    left=np.zeros_like(mask,dtype=bool);above=np.zeros_like(mask,dtype=bool)
    left[:,1:]=mask[:,1:]==mask[:,:-1]
    above[1:,:]=mask[1:,:]==mask[:-1,:]
    return np.where((mask!=0)&(left|above),mask,0).astype(np.uint8)


def centroid(mask,colour):
    yy,xx=np.nonzero(mask==colour)
    n=len(xx)
    return dict(area=n,valid=n>=32,cx=int(xx.sum()//n) if n else 0,
                cy=int(yy.sum()//n) if n else 0)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('capture',type=Path);ap.add_argument('--out',type=Path)
    a=ap.parse_args();out=a.out or a.capture/'analysis';out.mkdir(parents=True,exist_ok=True)
    info=json.loads((a.capture/'results.json').read_text())
    if not info.get('crc_ok') or info.get('pixel_format')!='RGB565':
        raise SystemExit('First decode a CRC-valid RGB565 dump using the course decoder.')
    w,h=info['width'],info['height']
    p=np.array([int(line,16) for line in (a.capture/'frame.hex').read_text().splitlines()],dtype=np.uint16).reshape(h,w)
    r=(p>>11)&31;g=(p>>5)&63;b=p&31
    rgb=np.stack(((r<<3)|(r>>2),(g<<2)|(g>>4),(b<<3)|(b>>2)),axis=2).astype(np.uint8)
    profile={}
    if info.get('n_results')==78 and info['results'][:2]==[0x45504132,2]:
        config=info['results'][77]
        profile=dict(ratio_red_min=(config>>24)&255,ratio_blue_min=(config>>16)&255,
                     ratio_num=(config>>8)&255,ratio_den=config&255)
    predictions=classify(rgb,**profile)
    report=dict(kind='software predictions; not measured FPGA candidate results',
                coordinates='native camera, before VGA rotation',width=w,height=h,
                dump_sha256=hashlib.sha256((a.capture/'dump.bin').read_bytes()).hexdigest(),
                crc_from_course_decoder=info['crc'],algorithms={})
    panels=[('Raw native camera',rgb)]
    for name,mask in predictions.items():
        clean=cleanup(mask)
        result=candidates(clean.tolist())
        report['algorithms'][name]=dict(raw_red=centroid(mask,1),raw_blue=centroid(mask,2),
                                       cleaned_candidates=result)
        (out/f'{name}_mask.hex').write_text(''.join(f'{v:x}\n' for v in mask.ravel()))
        (out/f'{name}_clean_mask.hex').write_text(''.join(f'{v:x}\n' for v in clean.ravel()))
        view=np.zeros_like(rgb);view[mask==1]=[255,40,40];view[mask==2]=[40,90,255]
        panels.append((f'{name.upper()} mask prediction',view))
    # Nearest-neighbour scaling preserves individual pixel decisions.
    canvas=Image.new('RGB',(w*4,h*4+80),'#20252b');draw=ImageDraw.Draw(canvas)
    for i,(label,pixels) in enumerate(panels):
        xx=(i%2)*w*2;yy=(i//2)*(h*2+40)
        draw.text((xx+8,yy+8),label,fill='white')
        canvas.paste(Image.fromarray(pixels).resize((w*2,h*2),Image.Resampling.NEAREST),(xx,yy+30))
    canvas.save(out/'mask-comparison.png')
    (out/'predictions.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f'Software prediction report: {out / "predictions.json"}')
    for name,result in report['algorithms'].items():
        print(name,'raw areas R/B',result['raw_red']['area'],result['raw_blue']['area'],
              'candidate overflow',result['cleaned_candidates']['overflow'])


if __name__=='__main__':main()
