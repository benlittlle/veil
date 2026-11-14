#!/usr/bin/env python3
"""Generates the Veil app icon (concept C) as a clean, editable SVG in several colourways.

Every colour is a named palette entry, so a new colourway is one dict below.
Usage: python3 make_icon.py [outdir]   -> writes veil-icon-<name>.svg per palette
"""
import sys, pathlib

PALETTES = {
    # name: tile top, tile bottom, bubble, bubble shade, veil, veil edge/glow
    "clay-night":  dict(tile1="#2B2A31", tile2="#16161B", bubble="#D0714F", shade="#B4593B", veil="#F2E4D6", glow="#FFE6CC"),
    "cream":       dict(tile1="#FFF9F1", tile2="#F1E4D4", bubble="#C9684A", shade="#AE543A", veil="#FFFFFF", glow="#FFFFFF"),
    "clay":        dict(tile1="#C9714F", tile2="#A9533A", bubble="#FBF1E6", shade="#EADBCB", veil="#FFFFFF", glow="#FFF4EA"),
    "ocean-night": dict(tile1="#1E2A36", tile2="#0F161E", bubble="#4F8FC0", shade="#3A6F99", veil="#E3EEF7", glow="#CFE6FF"),
    "sage":        dict(tile1="#E9EFE6", tile2="#D3DECF", bubble="#5E7F63", shade="#4A684F", veil="#FFFFFF", glow="#FFFFFF"),
    "plum-night":  dict(tile1="#2A2230", tile2="#16111A", bubble="#B5658F", shade="#924C72", veil="#F3E6EE", glow="#FFD9EE"),
    "mono":        dict(tile1="#2A2A2E", tile2="#141416", bubble="#8E8E93", shade="#6E6E73", veil="#F5F5F7", glow="#FFFFFF"),
}

BUBBLE = ("M560 400 C672 400 760 486 760 596 C760 706 672 790 560 790 C530 790 502 784 476 773 "
          "L404 818 C392 825 380 815 384 802 L404 738 C376 703 360 651 360 596 C360 486 448 400 560 400 Z")
# Veil: a dome over the bubble's top half, flaring at both hems, with a soft wave along its lower edge.
VEIL = ("M512 300 C640 300 720 380 744 470 C756 516 772 548 808 572 C826 584 820 600 800 604 "
        "C770 610 742 600 716 588 C670 566 640 552 600 560 C548 570 512 610 456 622 "
        "C400 634 352 624 312 650 C290 664 266 658 276 636 C292 602 300 570 304 530 "
        "C312 410 392 300 512 300 Z")

def svg(p):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p['tile1']}"/><stop offset="1" stop-color="{p['tile2']}"/>
    </linearGradient>
    <linearGradient id="bubble" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p['bubble']}"/><stop offset="1" stop-color="{p['shade']}"/>
    </linearGradient>
    <linearGradient id="veil" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{p['veil']}" stop-opacity="0.97"/>
      <stop offset="1" stop-color="{p['veil']}" stop-opacity="0.88"/>
    </linearGradient>
    <filter id="glow" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="18"/>
    </filter>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity="0.28"/>
    </filter>
  </defs>
  <rect id="tile-shape" x="100" y="100" width="824" height="824" rx="186" fill="url(#tile)" filter="url(#shadow)"/>
  <path id="bubble-shape" d="{BUBBLE}" fill="url(#bubble)"/>
  <path id="veil-glow" d="{VEIL}" fill="{p['glow']}" opacity="0.45" filter="url(#glow)"/>
  <path id="veil-shape" d="{VEIL}" fill="url(#veil)" stroke="{p['glow']}" stroke-opacity="0.9" stroke-width="5" stroke-linejoin="round"/>
</svg>
'''

out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
out.mkdir(parents=True, exist_ok=True)
for name, p in PALETTES.items():
    (out / f"veil-icon-{name}.svg").write_text(svg(p))
print("wrote", len(PALETTES), "colourways to", out)
