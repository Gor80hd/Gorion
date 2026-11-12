#!/usr/bin/env python3
"""Переносит географические таблицы из Flutter-эталона в ядро на Rust.

    python3 tool/globe/export_geo_tables.py

Читает (только текст, без запуска Dart):
  lib/features/home/utils/globe_country_codes.dart   — коды стран карты планеты
  lib/features/home/utils/map_location_resolver.dart — координаты, синонимы,
                                                       ключевые слова мест
Пишет core/crates/gorion-core/src/geo_data.rs. Пока Flutter-версия жива,
правки — в эталоне и повторный запуск; после этапа 6 — прямо в geo_data.rs.
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CODES = os.path.join(ROOT, 'lib/features/home/utils/globe_country_codes.dart')
RESOLVER = os.path.join(ROOT, 'lib/features/home/utils/map_location_resolver.dart')
OUT = os.path.join(ROOT, 'core/crates/gorion-core/src/geo_data.rs')


def block(text, name):
    start = text.index(name)
    open_brace = text.index('{', start) if 'Map' in text[start - 40:start] else text.index('[', start)
    close = text.index('};' if text[open_brace] == '{' else '];', open_brace)
    return text[open_brace + 1:close]


def num(value):
    value = value.strip()
    return value if '.' in value else value + '.0'


def main():
    codes_src = open(CODES, encoding='utf-8').read()
    resolver = open(RESOLVER, encoding='utf-8').read()

    codes = re.findall(r"'([A-Z]{2})'", block(codes_src, 'globeCountryIsoCodes'))
    pair = re.compile(r"'([^']+)':\s*\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)")
    lat_lon = pair.findall(block(resolver, '_countryLatLon ='))
    keywords = pair.findall(block(resolver, '_locationKeywords ='))
    aliases = re.findall(r"'([A-Z]{2})':\s*'([A-Z]{2})'", block(resolver, '_countryCodeAliases ='))
    fallback = re.search(r'defaultMapFallbackLatLon = \((-?[\d.]+), (-?[\d.]+)\)', resolver).groups()
    source = re.search(r'defaultSourceFallbackLatLon = \((-?[\d.]+), (-?[\d.]+)\)', resolver).groups()

    out = [
        '//! Сгенерировано tool/globe/export_geo_tables.py из Flutter-эталона.',
        '//! Не редактируйте вручную, пока жива Flutter-версия.',
        '',
        '/// Коды стран карты планеты: значение пикселя `world_map_countries.png` − 1.',
        'pub const GLOBE_COUNTRY_CODES: &[&str] = &[',
        *[f'    "{c}",' for c in codes],
        '];',
        '',
        f'pub const DEFAULT_MAP_FALLBACK: (f64, f64) = ({num(fallback[0])}, {num(fallback[1])});',
        f'pub const DEFAULT_SOURCE_FALLBACK: (f64, f64) = ({num(source[0])}, {num(source[1])});',
        '',
        '/// Центр страны (широта, долгота).',
        'pub const COUNTRY_LAT_LON: &[(&str, (f64, f64))] = &[',
        *[f'    ("{k}", ({num(a)}, {num(b)})),' for k, a, b in lat_lon],
        '];',
        '',
        'pub const COUNTRY_CODE_ALIASES: &[(&str, &str)] = &[',
        *[f'    ("{a}", "{b}"),' for a, b in aliases],
        '];',
        '',
        '/// Места по ключевым словам в имени сервера или данных IP.',
        'pub const LOCATION_KEYWORDS: &[(&str, (f64, f64))] = &[',
        *[f'    ("{k}", ({num(a)}, {num(b)})),' for k, a, b in keywords],
        '];',
        '',
    ]
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out))
    print(f'{OUT}: {len(codes)} кодов, {len(lat_lon)} стран, {len(keywords)} мест, {len(aliases)} синонимов')


if __name__ == '__main__':
    main()
