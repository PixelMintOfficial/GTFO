#!/usr/bin/env python3
"""
Writes a Godot 4 SpriteFrames resource for the astronaut from astronaut.json.

    python tools/godot_spriteframes.py

Every animation/direction pair becomes one animation named "<anim>_<dir>"
(e.g. "walk_SE"), with frames cut from the sprite sheets as AtlasTextures.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SPRITES = os.path.join(ROOT, 'assets', 'characters', 'astronaut')
OUT = os.path.join(SPRITES, 'astronaut_frames.tres')


def res_path(path):
    return 'res://' + os.path.relpath(path, ROOT).replace(os.sep, '/')


def main():
    with open(os.path.join(SPRITES, 'astronaut.json')) as fh:
        m = json.load(fh)
    fw, fh_ = m['frame_size']
    ext, subs, anims = [], [], []
    for ai, (name, a) in enumerate(m['animations'].items()):
        ext_id = f'{ai + 1}_{name}'
        ext.append(f'[ext_resource type="Texture2D" path="{res_path(os.path.join(SPRITES, a["file"]))}" id="{ext_id}"]')
        for row, d in enumerate(a['directions']):
            frames = []
            for col in range(a['frames']):
                sid = f'Atlas_{name}_{d}_{col}'
                subs.append(f'[sub_resource type="AtlasTexture" id="{sid}"]\n'
                            f'atlas = ExtResource("{ext_id}")\n'
                            f'region = Rect2({col * fw}, {row * fh_}, {fw}, {fh_})\n')
                frames.append('{\n"duration": 1.0,\n"texture": SubResource("%s")\n}' % sid)
            anims.append('{\n"frames": [%s],\n"loop": %s,\n"name": &"%s_%s",\n"speed": %.1f\n}'
                         % (', '.join(frames), 'true' if a['loop'] else 'false', name, d, a['fps']))
    out = [f'[gd_resource type="SpriteFrames" load_steps={len(ext) + len(subs) + 1} format=3]', '']
    out += ext + [''] + subs
    out += ['[resource]', 'animations = [%s]' % ', '.join(anims), '']
    with open(OUT, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('\n'.join(out))
    print(f'wrote {OUT} ({len(anims)} animations, {len(subs)} frames)')


if __name__ == '__main__':
    main()
