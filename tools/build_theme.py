#!/usr/bin/env python3
"""Convert user-owned pictures into a portable 11-state theme; never alters inputs."""
import argparse
import json
import itertools
from pathlib import Path
from PIL import Image, ImageDraw, ImageSequence, ImageOps

MOODS = ('welcome','idle','focus','happy','hot','dizzy','puzzled','sleepy','low','shy','message')
EXTENSIONS = {'.png','.jpg','.jpeg','.gif','.bmp','.webp'}

def demo(mood, frame):
    # Original geometric example, drawn from primitives without external reference artwork.
    im = Image.new('RGBA', (256,256)); draw = ImageDraw.Draw(im)
    dy = [0,-2,0][frame]
    color = '#A9E2CA' if mood not in ('low','sleepy') else '#BFCFD7'
    draw.ellipse((55,211,201,231),fill=(70,105,100,28))
    draw.rounded_rectangle((58,65+dy,198,220+dy),radius=65,fill=color,outline='#426E64',width=4)
    draw.ellipse((48,153+dy,85,196+dy),fill=color,outline='#426E64',width=4)
    draw.ellipse((171,153+dy,208,196+dy),fill=color,outline='#426E64',width=4)
    draw.ellipse((82,207+dy,116,232+dy),fill='#ECF9F2',outline='#426E64',width=3)
    draw.ellipse((140,207+dy,174,232+dy),fill='#ECF9F2',outline='#426E64',width=3)
    if mood in ('sleepy','low') or frame == 1:
        draw.line((91,130+dy,110,132+dy),fill='#34584F',width=5)
        draw.line((145,132+dy,164,130+dy),fill='#34584F',width=5)
    elif mood=='dizzy':
        for x in (101,155):
            draw.line((x-8,122+dy,x+8,138+dy),fill='#34584F',width=4)
            draw.line((x-8,138+dy,x+8,122+dy),fill='#34584F',width=4)
    else:
        draw.ellipse((96,122+dy,106,139+dy),fill='#34584F')
        draw.ellipse((150,122+dy,160,139+dy),fill='#34584F')
    if mood in ('happy','welcome','shy','message'):
        draw.arc((112,137+dy,144,163+dy),0,180,fill='#34584F',width=4)
    else: draw.line((119,153+dy,137,153+dy),fill='#34584F',width=3)
    if mood=='shy':
        draw.ellipse((77,143+dy,98,154+dy),fill='#F4B9BA');draw.ellipse((158,143+dy,179,154+dy),fill='#F4B9BA')
    if mood=='focus':
        draw.rounded_rectangle((84,115+dy,118,143+dy),radius=6,outline='#34584F',width=3)
        draw.rounded_rectangle((138,115+dy,172,143+dy),radius=6,outline='#34584F',width=3)
        draw.line((118,127+dy,138,127+dy),fill='#34584F',width=3)
    if mood=='hot':draw.ellipse((177,102,187,122),fill='#89BDE5')
    if mood=='puzzled':draw.arc((176,54,198,79),180,470,fill='#6E8DB4',width=4);draw.ellipse((182,85,186,89),fill='#6E8DB4')
    if mood=='message':
        draw.polygon([(205,64),(209,75),(220,79),(209,83),(205,94),(201,83),(190,79),(201,75)],fill='#E9C267')
    return im

def build(source, output, layout='single', use_demo=False):
    output = output.resolve()
    if output.exists() and any(output.iterdir()):raise ValueError('Output folder must be empty; existing files are never overwritten.')
    inputs = [] if use_demo else sorted(p for p in source.iterdir() if p.is_file() and p.suffix.lower() in EXTENSIONS)
    if not use_demo and not inputs:raise ValueError('No supported pictures in input folder.')
    if any(p.resolve().is_relative_to(output) for p in inputs):raise ValueError('Inputs and output must be separate.')
    decoded = {}
    for p in inputs:
        if p.stat().st_size>32*1024*1024:raise ValueError('Input file exceeds 32 MiB: '+p.name)
        with Image.open(p) as image:
            if image.width*image.height>32_000_000:raise ValueError('Input exceeds 32 megapixels: '+p.name)
            if layout=='strip':
                if image.width%3:raise ValueError('Strip width must be divisible by three: '+p.name)
                rgba=image.convert('RGBA'); w=image.width//3
                frames=[rgba.crop((i*w,0,(i+1)*w,image.height)) for i in range(3)]
            else:
                frames=[ImageOps.exif_transpose(frame.copy()).convert('RGBA') for frame in itertools.islice(ImageSequence.Iterator(image), 3)]
            normalized=[]
            for frame in frames:
                if frame.getchannel('A').getbbox() is None:raise ValueError('Image is fully transparent: '+p.name)
                frame.thumbnail((224,224),Image.Resampling.LANCZOS)
                cell=Image.new('RGBA',(256,256));cell.alpha_composite(frame,((256-frame.width)//2,(256-frame.height)//2));normalized.append(cell)
            decoded[p.stem.lower()]=normalized
    output.mkdir(parents=True,exist_ok=True)
    fallback=decoded.get('idle') or (next(iter(decoded.values())) if decoded else None)
    for mood in MOODS:
        cells=[demo(mood,i) for i in range(3)] if use_demo else decoded.get(mood,fallback)
        sheet=Image.new('RGBA',(768,256))
        for i in range(3):sheet.alpha_composite(cells[i%len(cells)],(i*256,0))
        sheet.save(output/(mood+'.png'))
    metadata={'version':1,'layout':'three-frame-strip','moods':list(MOODS),'name':'Geometric demo' if use_demo else 'User-provided theme',
        'rights':'Project-created geometric demo; see project license' if use_demo else 'Original image rights retained; no rights granted by converter'}
    (output/'theme.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2))
    return metadata

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=Path);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--layout',choices=['single','strip'],default='single');p.add_argument('--demo',action='store_true')
    a=p.parse_args()
    if not a.demo and a.input is None:p.error('--input is required unless --demo is used')
    print(json.dumps(build(a.input,a.output,a.layout,a.demo),ensure_ascii=False))
