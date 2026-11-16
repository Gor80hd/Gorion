#!/usr/bin/env python3
"""Generates the country-indexed world map used by the dot globe.

Downloads Natural Earth 110m admin-0 countries GeoJSON (cached next to this
script), rasterizes every country as a unique 8-bit index into an
equirectangular PNG and rewrites `GLOBE_COUNTRY_CODES` in the core's
geo_data.rs (index -> ISO 3166-1 alpha-2). Pixel value 0 means ocean; value N
means country N-1 in that list.

Usage:
    python3 tool/globe/generate_world_map.py
"""

import json
import math
import os
import sys
import urllib.request

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
GEOJSON_CACHE = os.path.join(HERE, 'ne_50m_admin_0_countries.geojson')
GEOJSON_URL = (
    'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/'
    'master/geojson/ne_50m_admin_0_countries.geojson'
)
OUT_PNG = os.path.join(ROOT, 'assets', 'images', 'world_map_countries.png')
OUT_RUST = os.path.join(ROOT, 'core', 'crates', 'gorion-core', 'src',
                        'geo_data.rs')

HI_W, HI_H = 4096, 2048   # rasterization resolution
LO_W, LO_H = 2048, 1024   # final asset resolution (max-pooled)


def download_geojson():
    if os.path.exists(GEOJSON_CACHE):
        return
    print('Downloading Natural Earth countries...')
    urllib.request.urlretrieve(GEOJSON_URL, GEOJSON_CACHE)


def iso_code_of(props):
    for key in ('ISO_A2', 'ISO_A2_EH', 'WB_A2', 'ADM0_A3'):
        value = props.get(key)
        if value and value != '-99' and len(value) == 2:
            return value
    return None


def project(lon, lat, width, height):
    x = (max(-180.0, min(180.0, lon)) + 180.0) / 360.0 * width
    y = (90.0 - max(-90.0, min(90.0, lat))) / 180.0 * height
    return (x, y)


def draw_ring(draw, ring, width, height, value):
    points = [project(lon, lat, width, height) for lon, lat in ring]
    if len(points) >= 3:
        draw.polygon(points, fill=value)


def draw_feature(draw, geometry, width, height, value):
    if geometry is None:
        return
    kind = geometry.get('type')
    coords = geometry.get('coordinates')
    if kind == 'Polygon':
        polygons = [coords]
    elif kind == 'MultiPolygon':
        polygons = coords
    else:
        return
    for polygon in polygons:
        if not polygon:
            continue
        draw_ring(draw, polygon[0], width, height, value)
        for hole in polygon[1:]:
            draw_ring(draw, hole, width, height, 0)


def max_pool(image, factor):
    """Downsample by `factor` keeping the max pixel (small countries win)."""
    sw, sh = image.size
    dw, dh = sw // factor, sh // factor
    src = image.load()
    out = Image.new('L', (dw, dh))
    dst = out.load()
    for y in range(dh):
        for x in range(dw):
            m = 0
            for dy in range(factor):
                for dx in range(factor):
                    v = src[x * factor + dx, y * factor + dy]
                    if v > m:
                        m = v
            dst[x, y] = m
    return out


def main():
    download_geojson()
    with open(GEOJSON_CACHE, 'r', encoding='utf-8') as fh:
        geo = json.load(fh)

    entries = []
    for feature in geo['features']:
        code = iso_code_of(feature.get('properties', {}))
        if code is None:
            continue
        entries.append((code, feature['geometry']))

    entries.sort(key=lambda entry: entry[0])
    codes = []
    for code, _ in entries:
        if code not in codes:
            codes.append(code)
    index_of = {code: position + 1 for position, code in enumerate(codes)}
    if len(codes) > 254:
        raise SystemExit('Too many countries for 8-bit indexing')

    hi = Image.new('L', (HI_W, HI_H), 0)
    draw = ImageDraw.Draw(hi)
    for code, geometry in entries:
        draw_feature(draw, geometry, HI_W, HI_H, index_of[code])

    lo = max_pool(hi, 2)
    lo.save(OUT_PNG, optimize=True)
    print('Wrote %s (%d countries)' % (OUT_PNG, len(codes)))

    write_codes(codes)


def write_codes(codes):
    """Заменяет `GLOBE_COUNTRY_CODES` в geo_data.rs ядра."""
    with open(OUT_RUST, encoding='utf-8') as fh:
        text = fh.read()
    start = text.index('pub const GLOBE_COUNTRY_CODES: &[&str] = &[')
    end = text.index('];', start) + 2
    rows = []
    for i in range(0, len(codes), 16):
        rows.append('    ' + ' '.join('"%s",' % c for c in codes[i:i + 16]))
    block = 'pub const GLOBE_COUNTRY_CODES: &[&str] = &[\n' + '\n'.join(rows) + '\n];'
    with open(OUT_RUST, 'w', encoding='utf-8') as fh:
        fh.write(text[:start] + block + text[end:])
    print('Wrote %s' % OUT_RUST)

if __name__ == '__main__':
    sys.exit(main())
