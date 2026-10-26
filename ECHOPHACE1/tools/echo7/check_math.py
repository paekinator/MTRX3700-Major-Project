#!/usr/bin/env python3
"""ECHO-7 team / OpenAI Codex AI-assisted mathematical verification.
This checks arithmetic choices, NOT execution or simulation of SystemVerilog RTL.
"""
from fractions import Fraction
from pathlib import Path
import json

def channels(p):
    r=(p>>11)&31; g=(p>>5)&63; b=p&31
    return r*8+r//4,g*4+g//16,b*8+b//4
def hsv_cross(r,g,b):
    v=max(r,g,b); d=v-min(r,g,b)
    if d==0 or v<80 or 255*d<96*v: return 0
    if v==r: n=256*(g-b)+(1536*d if g<b else 0)
    elif v==g: n=512*d+256*(b-r)
    else: n=1024*d+256*(r-g)
    assert 0<=n<1536*d and n<2**19
    red=n<=85*d or n>=1451*d
    blue=853*d<=n<=1109*d
    return 0 if red==blue else 1 if red else 2
def hsv_rational(r,g,b):
    v=max(r,g,b); minimum=min(r,g,b); delta=v-minimum
    if not delta or v<80: return 0
    # Independent textbook HSV in turns, evaluated with exact rational arithmetic.
    rc=Fraction(v-r,delta); gc=Fraction(v-g,delta); bc=Fraction(v-b,delta)
    if r==v: h=bc-gc
    elif g==v: h=2+rc-bc
    else: h=4+gc-rc
    h=(h/6)%1
    sat=Fraction(delta,v)
    if sat<Fraction(96,255): return 0
    red=h<=Fraction(85,1536) or h>=Fraction(1451,1536)
    blue=Fraction(853,1536)<=h<=Fraction(1109,1536)
    return 0 if red==blue else 1 if red else 2
def main():
    counts={'fixed':[0,0,0],'ratio':[0,0,0],'hsv':[0,0,0]}
    for p in range(65536):
        r,g,b=channels(p)
        fixed=1 if r>=160 and g<=100 and b<=100 else 2 if b>=160 and r<=100 and g<=100 else 0
        red=r>=80 and 2*r>=3*g and 2*r>=3*b
        blue=b>=80 and 2*b>=3*r and 2*b>=3*g
        ratio=0 if red==blue else 1 if red else 2
        hsv=hsv_cross(r,g,b)
        assert hsv==hsv_rational(r,g,b),(hex(p),hsv,hsv_rational(r,g,b))
        # Check lossless inverse of the actual camera_display 30-bit packing.
        packed=(r<<22)|(g<<12)|(b<<2)
        recovered=(((packed>>25)&31)<<11)|(((packed>>14)&63)<<5)|((packed>>5)&31)
        assert recovered==p
        counts['fixed'][fixed]+=1; counts['ratio'][ratio]+=1; counts['hsv'][hsv]+=1
    assert counts['fixed']==[57736,3900,3900]
    print(json.dumps({'status':'PASS','scope':'Python mathematical checks only; NOT RTL simulation',
        'cases':65536,'checks':['HSV cross-products vs exact rational HSV','19-bit hue range','RGB565/30-bit round trip','fixed mask counts'],
        'counts_background_red_blue':counts},indent=2))
if __name__=='__main__': main()
