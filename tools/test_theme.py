import json
from pathlib import Path
import tempfile
import unittest
from PIL import Image
from build_theme import build, MOODS

class ThemeTests(unittest.TestCase):
    def test_single_picture_reuses_all_states_and_preserves_input(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);source=root/'input';source.mkdir();path=source/'my character.png'
            Image.new('RGBA',(50,90),'#abcdef').save(path);original=path.read_bytes()
            out=root/'theme';build(source,out)
            self.assertEqual(path.read_bytes(),original)
            self.assertEqual(len(list(out.glob('*.png'))),11)
            self.assertEqual((out/'idle.png').read_bytes(),(out/'happy.png').read_bytes())
            with Image.open(out/'idle.png') as image:self.assertEqual(image.size,(768,256))
    def test_named_state_override_and_missing_fallback(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);source=root/'input';source.mkdir()
            Image.new('RGBA',(40,70),'red').save(source/'idle.png');Image.new('RGBA',(40,70),'blue').save(source/'happy.png')
            out=root/'out';build(source,out)
            self.assertNotEqual((out/'happy.png').read_bytes(),(out/'idle.png').read_bytes())
            self.assertEqual((out/'hot.png').read_bytes(),(out/'idle.png').read_bytes())
    def test_does_not_overwrite_existing_output(self):
        with tempfile.TemporaryDirectory() as root:
            out=Path(root)/'out';out.mkdir();existing=out/'keep.txt';existing.write_text('keep')
            with self.assertRaises(ValueError):build(None,out,use_demo=True)
            self.assertEqual(existing.read_text(),'keep')
    def test_strip_preserves_three_distinct_frames(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);source=root/'in';source.mkdir();im=Image.new('RGBA',(90,60))
            for i,color in enumerate(['red','green','blue']):im.paste(color,(i*30,0,(i+1)*30,60))
            im.save(source/'idle.png');out=root/'out';build(source,out,layout='strip')
            with Image.open(out/'idle.png') as image:self.assertNotEqual(image.getpixel((128,128)),image.getpixel((384,128)))
    def test_rejects_empty_transparent_picture(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);source=root/'in';source.mkdir();Image.new('RGBA',(40,40)).save(source/'idle.png')
            with self.assertRaises(ValueError):build(source,root/'out')
    def test_demo_has_complete_manifest_and_visible_frames(self):
        with tempfile.TemporaryDirectory() as root:
            out=Path(root)/'out';build(None,out,use_demo=True)
            self.assertEqual(json.loads((out/'theme.json').read_text())['moods'],list(MOODS))
            for mood in MOODS:
                with Image.open(out/(mood+'.png')) as image:self.assertIsNotNone(image.getchannel('A').getbbox())

if __name__=='__main__':unittest.main()
