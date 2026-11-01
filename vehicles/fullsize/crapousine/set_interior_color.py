"""Sets the colour of the Crapousine interior (part "Crapousine Interior"): dash, doors, seats, carpet and the
limousine's rear cabin. Run it from this folder, then Ctrl+R the car in the game:

    python set_interior_color.py "#5A2266"        (a colour as a web/hex code, as most colour pickers give it)
    python set_interior_color.py 90 34 102        (red, green, blue from 0 to 255)

The stock colours, for reference: black #212121, night blue #1C2136, blue #506C81, red #692A2F, tan #9C7858.
The colour tints the interior's own (grey) textures, so it comes out a bit darker than the code.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, 'crapousine.materials.json')
MATERIALS = ['fullsize_interior', 'fullsize_intcarpet', 'limo_interior', 'limo_interior_on']

args = sys.argv[1:]
try:
    if len(args) == 1 and len(args[0].lstrip('#')) == 6:
        code = args[0].lstrip('#')
        rgb = [int(code[i:i + 2], 16) for i in (0, 2, 4)]
    elif len(args) == 3:
        rgb = [int(a) for a in args]
    else:
        raise ValueError
except ValueError:
    sys.exit(__doc__)
if any(not 0 <= c <= 255 for c in rgb):
    sys.exit('each of red, green and blue goes from 0 to 255')

with open(PATH, encoding='utf-8') as f:
    mats = json.load(f)
for base in MATERIALS:
    stages = mats[base + '.skin_interior.crapousine']['Stages']
    for st in stages:
        if isinstance(st.get('baseColorFactor'), list):
            st['baseColorFactor'] = [round(c / 255, 4) for c in rgb] + [1]
with open(PATH, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(mats, f, indent=2)
print('Crapousine interior set to #%02X%02X%02X; press Ctrl+R in the car to see it.' % tuple(rgb))
