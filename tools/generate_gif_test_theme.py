"""Deterministic, original geometric animation; Pillow is a dev-only dependency."""
from pathlib import Path
from PIL import Image, ImageDraw
import json, zipfile
root = Path(__file__).resolve().parents[1]
folder = root / 'TestThemes/MinimalGif'
folder.mkdir(parents=True, exist_ok=True)
frames = []
for i in range(8):
    image = Image.new('RGBA', (96, 96), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    x = 10 + i * 8
    draw.ellipse((x, 32, x+24, 56), fill=(20, 180, 160, 255))
    draw.rectangle((x+6, 40, x+8, 43), fill='white')
    draw.rectangle((x+16, 40, x+18, 43), fill='white')
    frames.append(image)
delays = [40, 80, 120, 160, 200, 240, 280, 320]
frames[0].save(folder/'demo.gif', save_all=True, append_images=frames[1:], duration=delays, loop=0, disposal=2, optimize=False)
(folder/'theme.json').write_text(json.dumps({'format':'dynapet-theme', 'version':1, 'name':'Moving Dot (8 frames)', 'states':{'idle':'demo.gif','touch':'demo.gif','sleep':'demo.gif'}}, indent=2)+'\n')
(folder/'README.txt').write_text('DynaPet cross-platform test theme. Import this folder using Import Theme Package.\n8 frames, distinct delays 40..320 ms, infinite looping, transparent canvas and moving dot.\nOriginal geometric artwork; CC0-1.0. No third-party character assets.\n', encoding='utf-8')
# Additional conformance fixtures: same pixels, finite/absent loop extensions,
# transparent delta rectangles, disposal 1/2/3, and zero/minimum delays.
fixtures = root / 'TestThemes/Conformance'
fixtures.mkdir(parents=True, exist_ok=True)
for name, kwargs in [('once', {}), ('finite', {'loop':2}), ('disposal', {'loop':0, 'disposal':[1,2,3,1,2,3,1,2]})]:
    options = dict(duration=delays, disposal=2, optimize=True); options.update(kwargs)
    frames[0].save(fixtures/(name+'.gif'), save_all=True, append_images=frames[1:], **options)
frames[0].save(fixtures/'zero-delay.gif', save_all=True, append_images=frames[1:], duration=[0,10,20,40,80,100,200,300], loop=0, disposal=2)
(fixtures/'theme.json').write_text(json.dumps({'format':'dynapet-theme','version':1,'name':'Distinct States','states':{'idle':'once.gif','touch':'finite.gif','sleep':'disposal.gif','focus':'zero-delay.gif'}},indent=2)+'\n')
expect = {}
for file in [folder/'demo.gif', *sorted(fixtures.glob('*.gif'))]:
    image = Image.open(file); samples = []
    for i in range(image.n_frames):
        image.seek(i)
        rgba = image.convert('RGBA')
        # FNV-1a of RGBA pixels, RGB cleared when alpha=0 to avoid irrelevant decoder differences.
        data=bytearray(rgba.tobytes())
        for p in range(0,len(data),4):
            if data[p+3]==0: data[p:p+3]=b'\0\0\0'
        h=2166136261
        for b in data: h=((h^b)*16777619)&0xffffffff
        samples.append({'delay':(image.info.get('duration',0) or 100)/1000,'rgbaFNV1a':f'{h:08x}'})
    image.seek(0)
    expect[file.name] = {'width':image.width,'height':image.height,'repeats':image.info.get('loop'),'frames':samples}
(fixtures/'expected.json').write_text(json.dumps(expect,indent=2)+'\n')
archive=root/'TestThemes/MinimalGif.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as zip:
    for file in sorted(folder.iterdir()): zip.write(file,'MinimalGif/'+file.name)
print(archive)
