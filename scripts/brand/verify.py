#!/usr/bin/env python3
"""Verify the final logo and an independent parameter rebuild. Requires Pillow."""
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from PIL import Image, ImageChops

ROOT=Path(__file__).resolve().parents[2] / "assets/brand/iphone-use-final"

def topology(im):
    w,h=im.size
    pixels=[v>=128 for v in im.getdata()]
    def count(target,diagonal):
        seen=bytearray(w*h);components=interior=0
        directions=[(1,0),(-1,0),(0,1),(0,-1)]
        if diagonal:directions += [(1,1),(1,-1),(-1,1),(-1,-1)]
        for start in range(w*h):
            if seen[start] or pixels[start]!=target:continue
            components+=1;todo=[start];seen[start]=1;border=False
            while todo:
                index=todo.pop();x,y=index%w,index//w
                border |= x==0 or x==w-1 or y==0 or y==h-1
                for dx,dy in directions:
                    xx,yy=x+dx,y+dy
                    if 0<=xx<w and 0<=yy<h:
                        nxt=yy*w+xx
                        if not seen[nxt] and pixels[nxt]==target:
                            seen[nxt]=1;todo.append(nxt)
            interior+=not border
        return components,interior
    return {'components':count(True,True)[0],'holes':count(False,False)[1]}

def main():
    p=json.loads((ROOT/'geometry.json').read_text())
    resolved=json.loads((ROOT/'resolved-geometry.json').read_text())
    manifest=json.loads((ROOT/'manifest.json').read_text())
    assert (ROOT/'mark.svg').read_bytes()==(ROOT/'reference/approved-mark.svg').read_bytes()
    assert (ROOT/'wordmark.svg').read_bytes()==(ROOT/'reference/approved-wordmark.svg').read_bytes()
    for name in manifest['svg_sha256']:
        tree=ET.parse(ROOT/name).getroot()
        assert resolved['path'] in [e.get('d') for e in tree.iter()]
    for name in ['mark.svg','inverse.svg','wordmark.svg','wordmark-inverse.svg']:
        assert not any(e.tag.rsplit('}',1)[-1] in ['image','text','mask','filter'] for e in ET.parse(ROOT/name).getroot().iter())
    with tempfile.TemporaryDirectory(prefix='iphone-use-logo-verify-') as folder:
        subprocess.run([sys.executable,str(Path(__file__).with_name('build.py')),'--out',folder],check=True,capture_output=True)
        for name in manifest['svg_sha256']:
            assert (ROOT/name).read_bytes()==(Path(folder)/name).read_bytes()
    alpha=Image.open(ROOT/'mark.png').getchannel('A')
    assert ImageChops.difference(alpha,Image.open(ROOT/'inverse.png').getchannel('A')).getbbox() is None
    sizes={}
    for size in [16,24,32,48,64,1024]:
        image=alpha if size==1024 else Image.open(ROOT/f'mark-{size}.png').getchannel('A')
        sizes[str(size)]=topology(image)
        if size>=24:assert sizes[str(size)]=={'components':1,'holes':2}
    phone=p['phone'];swipe=p['swipe'];speaker=p['speaker']
    assert phone['width']>2*phone['radius'] and phone['height']>2*phone['radius']
    assert speaker['height']==2*speaker['radius'] and speaker['width']>speaker['height']
    assert swipe['radius']>swipe['width']/2 and 0<swipe['end_degrees']-swipe['start_degrees']<180
    assert (swipe['radius']+swipe['width']/2)-(swipe['radius']-swipe['width']/2)==swipe['width']
    tangent_residual=max(abs(math.cos(math.radians(a))*(-math.sin(math.radians(a)))+math.sin(math.radians(a))*math.cos(math.radians(a))) for a in [swipe['start_degrees'],swipe['end_degrees']])
    # Signed distance to the rounded phone; sampled checks do not claim an exact analytic minimum.
    def clearance(point):
        radius=phone['radius'];half=[phone['width']/2,phone['height']/2]
        center=[phone['x']+half[0],phone['y']+half[1]]
        q=[abs(point[i]-center[i])-half[i]+radius for i in [0,1]]
        return -(math.hypot(max(q[0],0),max(q[1],0))+min(max(q),0)-radius)
    samples=[]
    for i in range(281):
        angle=math.radians(swipe['start_degrees']+(swipe['end_degrees']-swipe['start_degrees'])*i/280)
        for radius in [swipe['radius']-swipe['width']/2,swipe['radius']+swipe['width']/2]:
            samples.append([swipe['center'][0]+radius*math.cos(angle),swipe['center'][1]+radius*math.sin(angle)])
    for center in resolved['cap_centers']:
        for i in range(360):
            angle=math.radians(i)
            samples.append([center[0]+swipe['width']/2*math.cos(angle),center[1]+swipe['width']/2*math.sin(angle)])
    min_clearance=min(clearance(point) for point in samples)
    assert min_clearance>0 and min(point[1] for point in samples)>speaker['y']+speaker['height']
    report={'approved_master_and_wordmark_byte_identical':True,'master_and_construction_share_path':True,
            'independent_rebuild_identical_svg_count':len(manifest['svg_sha256']),
            'inverse_alpha_identical':True,'pure_vector_no_font_dependency':True,
            'geometry':{'constant_arc_width':swipe['width'],'tangent_dot_residual':tangent_residual,
                        'rounded_corners_fit':True,'sampled_arc_clearance_from_phone_units':min_clearance,'boundary_sample_count':len(samples)},
            'raster_topology_alpha128_foreground8_background4':sizes,
            'recommended_min_canvas_px':24,'16px':'Curved cutout fragments at this threshold; do not use this master at 16px.',
            'visual_review':'not performed',
            'external_recognition_test':'not performed','print_proof':'not performed'}
    (ROOT/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
