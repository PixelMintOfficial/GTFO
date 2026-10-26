#!/usr/bin/env python3
"""Physical O2 RESERVES repeater, native SDF housing + eleven battery frames in four views.

Uses the same wall-mount/export contract as the solar inlet. Native 3x5 decals are contained
inside one compact SDF frame. Wall repeaters are scored against final depth across all repair
variants so a tank cannot cover the readout after turns. Shared by every machine repair variant;
only the O2 reserve powers the live readout. --meter-only on interior_gen refreshes this
overlay/metadata without rerendering unchanged rooms, windows, collision or machines.
"""
import json
import math
from pathlib import Path
import numpy as np
from PIL import Image
import interior_gen as I

M, A, P = I.M, I.A, I.P_
ROOT = Path(M.ROOT) / 'assets/maps/base_interior'
TITLE = 'RESERVES'


def clear_fraction(center, angle, scenes):
    """Match the runtime depth test across the whole native face, not just its centre."""
    x,z = np.meshgrid(np.linspace(-11.,11.,45),np.linspace(-3.9,3.9,17))
    local = np.stack([x.ravel(),np.full(x.size,-.6),z.ravel()],axis=1)
    rotate = A.rz(math.radians(angle)-math.pi/2)
    points = M.to_view(center + local@rotate.T)
    px,py = M.project(*points.T)
    px,py = np.floor(px).astype(int),np.floor(py).astype(int)
    sprite_depth = M.to_view(center)[1]
    return min(float(np.mean(scene[py,px] >= sprite_depth-10.)) for scene in scenes)


def info(meta):
    """Choose a standing-wall repeater whose entire face clears the tanks in every variant."""
    scenes=[]
    for variant in ['', 'repaired_power', 'repaired_oxygen', 'repaired_both']:
        path=ROOT/variant/f'base_interior{M.SFX}.json'
        data=json.loads(path.read_text(encoding='utf-8'))
        depth=np.asarray(Image.open(path.parent/data['game']['depth_png'])).astype(float)
        scenes.append((depth[...,0]*256+depth[...,1])/float(data['game']['depth_scale']))
    candidates=[]
    for angle in [135.,225.,315.,45.]:
        if not I.label_visible(angle): continue
        center=I.room_pt('oxygen',angle,I.r_in('oxygen')-1.8,25.)
        candidates.append((clear_fraction(center,angle,scenes),angle,center))
    fraction,angle,center=max(candidates,key=lambda item:item[0])
    if fraction < .98: raise ValueError(f'view {M.VIEW}: no clear O2 reserve wall, best coverage {fraction}')
    return dict(world=center.tolist(), angle=angle, label=TITLE,clear_fraction=fraction,
                housing=f'reserve_meter/housing{M.view_sfx(M.VIEW)}.png',
                levels=f'reserve_meter/levels{M.view_sfx(M.VIEW)}.png')


def lettering(part, points):
    """Native 3x5 glyphs fitted inside the real SDF face, at one map pixel per glyph cell."""
    q = part.sdf.local(points)
    width = M.text_width(TITLE)
    # The whole design is scaled by .5. These design-size cells retain native pixel size.
    x = np.floor(q[:,0]/1.3 + width/2).astype(int)
    y = np.floor(2.5-q[:,2]/1.0).astype(int)
    glyphs = np.zeros((5,width),bool)
    cursor = 0
    for ch in TITLE:
        glyph = np.array([[bit=='#' for bit in row] for row in M.FONT[ch]])
        glyphs[:,cursor:cursor+glyph.shape[1]] = glyph
        cursor += glyph.shape[1]+1
    inside = (x>=0)&(x<width)&(y>=0)&(y<5)
    ink = inside.copy()
    ink[inside] = glyphs[y[inside],x[inside]]
    out = np.full(len(points),M.OID['darkwin'])
    out[ink] = M.OID['white' if part.name=='legend_plate' else 'window']
    return out


def build():
    (ROOT / 'reserve_meter').mkdir(exist_ok=True)
    M.SUN = I.SUN_IN
    for k in range(4):
        M.VIEW, M.SFX = k, M.view_sfx(k)
        meta = json.loads((ROOT / f'base_interior{M.SFX}.json').read_text(encoding='utf-8'))
        M.AX, M.AY = meta['origin_px']
        panel = info(meta)
        c = np.array(panel['world'])
        angle = math.radians(panel['angle'])
        rotate = A.rz(angle-math.pi/2)
        normal = np.array([math.cos(angle),math.sin(angle),0])
        def at(x,z,depth=1.): return c + rotate@np.array([x,0,z]) - normal*depth
        housing = [P('frame',A.RoundBox(c,[22,.9,7.8],.6,rotate),'steel','reserve'),
                   P('face',A.RoundBox(at(0,0,1.),[20.6,.3,6.5],.25,rotate),'darkwin','reserve'),
                   P('legend_plate',A.RoundBox(at(0,3.,1.35),[20.2,.12,2.7],.1,rotate),'darkwin','reserve',lettering),
                   P('lower_trim',A.RoundBox(at(0,-6.8,1.1),[19.7,.3,.25],.1,rotate),'coral','reserve')]
        for x in [-20,20]:
            for z in [-6,6]:
                housing.append(P('screw',A.Sphere(at(x,z,1.2),.45),'white','reserve'))
        frames=[]
        for level in range(11):
            parts=[P('legend_live',A.RoundBox(at(0,3.,1.35),[20.2,.12,2.7],.1,rotate),'darkwin','readout',lettering)]
            for segment in range(10):
                parts.append(P('bar',A.RoundBox(at(-17.1+segment*3.8,-3.,1.35),[1.25,.15,1.35],.1,rotate),
                               'window' if segment<level else 'darkwin','readout'))
            frames.append(M.turned(M.scaled(parts,c,.5,'reserve')))
        housing=M.turned(M.scaled(housing,c,.5,'reserve'))
        box=M.sprite_box([housing]+frames,pad=2)
        cover=M.sprite_rgba(M.render_sprite(housing,box))
        M.save_png(Image.fromarray(cover),str(ROOT/panel['housing']))
        pixels=np.concatenate([M.sprite_rgba(M.render_sprite(parts,box)) for parts in frames],axis=1)
        M.save_png(Image.fromarray(pixels),str(ROOT/panel['levels']))
        panel.update(position=list(box[:2]),size=list(box[2:]),frames=11,model_scale=.5)
        for variant in ['', 'repaired_power', 'repaired_oxygen', 'repaired_both']:
            path=ROOT/variant/f'base_interior{M.SFX}.json'
            data=json.loads(path.read_text(encoding='utf-8'))
            data['reserve_meter']=panel
            M.save_text(json.dumps(data,indent=1)+'\n',str(path))
    M.VIEW, M.SFX=0,''
    print('O2 RESERVES wall meter: native housing/11 levels, four views, all repair variants',flush=True)


if __name__=='__main__': build()
