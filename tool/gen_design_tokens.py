#!/usr/bin/env python3
"""Генерирует код токенов дизайна из design/tokens.json.

    python3 tool/gen_design_tokens.py

Пишет apps/macos/Packages/GorionDesign/Sources/GorionDesign/Generated/Tokens.swift.
Сгенерированный файл хранится в git, чтобы сборка не требовала генератора.
Правки — только в tokens.json, затем перезапуск генератора.
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
TOKENS = os.path.join(ROOT, 'design', 'tokens.json')
OUT = os.path.join(
    ROOT, 'apps', 'macos', 'Packages', 'GorionDesign', 'Sources', 'GorionDesign',
    'Generated', 'Tokens.swift',
)


def num(value):
    """Число как в JSON: целое без точки, дробное — кратчайшей записью."""
    if isinstance(value, bool):
        raise ValueError('ожидалось число')
    return str(value) if isinstance(value, int) else repr(float(value))


def camel(group, key):
    return group + key[0].upper() + key[1:]


def rgba(value):
    """"#RRGGBB" или "#RRGGBB/альфа" → `RGBA(0xRRGGBB, альфа)`."""
    parts = value.split('/')
    hex_part = parts[0].replace('#', '', 1)
    alpha = parts[1] if len(parts) > 1 else '1'
    return 'RGBA(0x%s, %s)' % (hex_part, alpha)


def dynamic(dark, light):
    return 'DynamicColor(dark: %s, light: %s)' % (rgba(dark), rgba(light))


def weight(value):
    if value >= 700:
        return '.bold'
    if value >= 600:
        return '.semibold'
    if value >= 500:
        return '.medium'
    return '.regular'


def swift(t):
    out = [
        '// Сгенерировано tool/gen_design_tokens.py из design/tokens.json.',
        '// Не редактируйте вручную.',
        '',
        'import SwiftUI',
        '',
    ]
    w = out.append

    color = t['color']
    w('public enum GColor {')
    for group in ('brand', 'text', 'status'):
        for key, value in color[group].items():
            w('    public static let %s = %s' % (camel(group, key), dynamic(value['dark'], value['light'])))
    ping = color['ping']
    unknown = ping['unknown']
    w('    public static let pingUnknown = %s' % dynamic(unknown['dark'], unknown['light']))
    w('    public static let pingGoodBelowMs = %s' % num(ping['goodBelowMs']))
    w('    public static let pingFairBelowMs = %s' % num(ping['fairBelowMs']))
    for key, value in color['settingsCategory'].items():
        w('    public static let %s = %s' % (camel('category', key), dynamic(value, value)))
    w('}')
    w('')

    glass = t['material']['glass']
    dark, light = glass['dark'], glass['light']
    w('/// Заливки — запасной вариант для «Снизить прозрачность» и мест без стекла.')
    w('public enum GMaterial {')
    for key in dark:
        w('    public static let %s = %s' % (key, dynamic(dark[key], light[key])))
    w('}')
    w('')

    w('public enum GRadius {')
    for key, value in t['radius']['glass'].items():
        w('    public static let %s: CGFloat = %s' % (key, num(value)))
    w('}')
    w('')

    w('public enum GSpacing {')
    for key, value in t['spacing'].items():
        w('    public static let %s: CGFloat = %s' % (key, num(value)))
    w('}')
    w('')

    layout = t['layout']
    window, sidebar = layout['window'], layout['sidebar']
    w('public enum GLayout {')
    for name, value in (
        ('windowDefaultWidth', window['defaultWidth']),
        ('windowDefaultHeight', window['defaultHeight']),
        ('windowMinWidth', window['minWidth']),
        ('windowMinHeight', window['minHeight']),
        ('sidebarMinWidth', sidebar['minWidth']),
        ('sidebarMaxWidth', sidebar['maxWidth']),
        ('sidebarFraction', sidebar['fractionOfWindow']),
        ('sidebarHeaderHeight', layout['sidebarHeaderHeight']),
        ('trafficLightsWidth', layout['trafficLightsWidth']),
        ('minHitTarget', layout['minHitTarget']['macos']),
    ):
        w('    public static let %s: CGFloat = %s' % (name, num(value)))
    w('}')
    w('')

    w('public enum GComponent {')
    for key, value in t['component'].items():
        if isinstance(value, (int, float)):
            w('    public static let %s: CGFloat = %s' % (key, num(value)))
        elif isinstance(value, dict):
            for sub, v in value.items():
                w('    public static let %s: CGFloat = %s' % (camel(key, sub), num(v)))
    w('}')
    w('')

    w('/// Планета: физика вращения, геометрия и цвета.')
    w('public enum GGlobe {')
    for key, value in t['globe'].items():
        if isinstance(value, (int, float)):
            kind = 'Int' if key == 'samples' else 'Double'
            w('    public static let %s: %s = %s' % (key, kind, num(value)))
        elif key == 'rate':
            for sub, v in value.items():
                w('    public static let %s: Double = %s' % (camel('rate', sub), num(v)))
        elif key == 'color':
            dark, light = value['dark'], value['light']
            for name in dark:
                if isinstance(dark[name], (int, float)):
                    w('    public static let %sOpacity = DynamicValue(dark: %s, light: %s)'
                      % (name, num(dark[name]), num(light[name])))
                else:
                    w('    public static let %sColor = %s' % (name, dynamic(dark[name], light[name])))
    w('}')
    w('')

    typography = t['typography']
    body = typography['bodySize']['macos']
    w('public enum GType {')
    for key, s in typography['scale'].items():
        size = body if s['size'] == 'body' else s['size']
        w('    public static let %s = TypeStyle(size: %s, weight: %s, tracking: %s, lineHeight: %s)'
          % (key, num(size), weight(s['weight']), num(s['tracking']), num(s['lineHeight'])))
    w('}')
    w('')

    motion = t['motion']
    rate = motion['inertia']['decelerationRate']
    press = motion['press']
    timing = motion['timing']
    w('public enum GMotion {')
    for key, s in motion['springs'].items():
        w('    public static let %s = SpringToken(response: %s, bounce: %s)'
          % (key, num(s['response']), num(s['bounce'])))
    w('    public static let decelerationNormal: Double = %s' % num(rate['normal']))
    w('    public static let decelerationFast: Double = %s' % num(rate['fast']))
    w('    public static let rubberBandCoefficient: CGFloat = %s' % num(motion['rubberBand']['coefficient']))
    w('    public static let pressScaleButton: CGFloat = %s' % num(press['scaleButton']))
    w('    public static let pressScaleSmallControl: CGFloat = %s' % num(press['scaleSmallControl']))
    w('    public static let pressScaleCard: CGFloat = %s' % num(press['scaleCard']))
    w('    public static let breatheScale: CGFloat = %s' % num(motion['breatheScale']))
    w('    public static let tooltipDelay: Duration = .milliseconds(%s)' % num(timing['tooltipDelayMs']))
    w('    public static let toastBase: Duration = .milliseconds(%s)' % num(timing['toastBaseMs']))
    w('    public static let toastPerWord: Duration = .milliseconds(%s)' % num(timing['toastPerWordMs']))
    w('    public static let toastMax: Duration = .milliseconds(%s)' % num(timing['toastMaxMs']))
    w('}')
    return '\n'.join(out) + '\n'


def main():
    with open(TOKENS, encoding='utf-8') as fh:
        tokens = json.load(fh)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as fh:
        fh.write(swift(tokens))
    print('Записано: %s' % OUT)


if __name__ == '__main__':
    main()
