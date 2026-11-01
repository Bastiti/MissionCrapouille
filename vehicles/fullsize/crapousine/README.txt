Crapousine - its badges and interior colour
============================================

New parts for the fullsize (Gavril Grand Marshal), picked in the parts menu; the stock parts and the other
Gavrils stay as they are. The "Crapousine" configuration (vehicles/fullsize/crapousine.pc) uses them all.

  Lettering          ->  Crapousine Lettering          the trunk: rear logo, rear letters, rear badge
  Grille Lettering   ->  Crapousine Grille Lettering   the grille: front logo, front badge
  Interior Color     ->  Crapousine Interior           dash, doors, seats, carpet and the rear cabin


Badges: crapousine_badges.color.png
-----------------------------------
One picture holds every sign of the car, each in its own box (2048 x 1024 pixels, about 8 pixels per mm on the
car). crapousine_badges_guide.png shows the boxes, their size on the car and where each one goes:

  REAR LETTERS   trunk lid, right side seen from behind      (stock: GRAND MARSHAL)   228 x 17 mm
  REAR LOGO      trunk lid, left side seen from behind       (stock: GAVRIL)           48 x 64 mm
  REAR BADGE     low on the trunk lid, left side             (stock: V8)               61 x 28 mm
  FRONT LOGO     grille, right side seen from the front      (stock: GAVRIL)           43 x 57 mm
  FRONT BADGE    grille, left side seen from the front       (stock: V8)               47 x 15 mm

It comes filled with CRAPOUSINE and V8, and the brand logo is the Crapouille fox of the Sunburst's lettering.
The two logo badges are cut to the fox's shape: an upright emblem in place of the stock GAVRIL word, on the
trunk lid's rear edge and in the grille's corner. To change them, open the picture in an editor that keeps
transparency (Paint.NET, GIMP, Photoshop, Krita...); the guide can go in a layer underneath, as a stencil.

  - Paint inside the boxes, upright, as you'd read them on the car. Anything outside a box never shows.
  - What's transparent isn't there; what's opaque is a metal badge (more than half opaque counts as opaque).
  - The colour you paint is the metal's colour: light grey/white is chrome, yellow is gold, any colour works.
  - An empty box hides that sign (e.g. no V8: erase both V8 boxes).
  - Keep the size (2048 x 1024) and save as PNG with transparency, under the same name.

Then, each time, make the badges' mask and relief from it:

    python make_badge_maps.py

It writes two pictures the game needs, both from your picture's transparency (a second or two):
  - crapousine_badges_o.data.png, the cut-out (white = metal, black = nothing): the game ignores a picture's own
    transparency and reads which parts exist from this one;
  - crapousine_badges_n.normal.png, the relief: every shape raised, with a rounded bevel along its edges, which is
    where chrome catches the light. Without it the badges look like flat stickers.
The game picks them up by itself while it runs (else Ctrl+R in the car).


Interior colour
---------------
The colour tints the interior's own textures. Set it with the little script next to this file:

    python set_interior_color.py "#5A2266"        (a web/hex colour code)
    python set_interior_color.py 90 34 102        (red, green, blue, 0 to 255)

then Ctrl+R in the car. It starts as plum (#52215C). The stock ones, for comparison: black #212121, night blue
#1C2136, blue #506C81, red #692A2F, tan #9C7858. (By hand: "baseColorFactor" of the four
*.skin_interior.crapousine materials in crapousine.materials.json, red / green / blue from 0 to 1.)


The other files
---------------
  crapousine_badges_o.data.png         the badges' cut-out mask (made by make_badge_maps.py)
  crapousine_badges_n.normal.png       the badges' relief (made by make_badge_maps.py)
  crapousine.jbeam                     the three parts
  crapousine.materials.json            the badges' material and the interior colour
  craptech_crapousine_lettering.dae    the badges' shapes: copies of the stock ones
