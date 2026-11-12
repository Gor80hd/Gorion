// Генерирует код токенов дизайна из design/tokens.json.
//
//   dart run tool/gen_design_tokens.dart
//
// Пишет apps/macos/Packages/GorionDesign/Sources/GorionDesign/Generated/Tokens.swift.
// Сгенерированный файл хранится в git, чтобы сборка не требовала Dart.
// Правки — только в tokens.json, затем перезапуск генератора.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final tokens =
      jsonDecode(File('$root/design/tokens.json').readAsStringSync())
          as Map<String, dynamic>;
  final out = File(
    '$root/apps/macos/Packages/GorionDesign/Sources/GorionDesign/Generated/Tokens.swift',
  );
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(_swift(tokens));
  stdout.writeln('Записано: ${out.path}');
}

String _swift(Map<String, dynamic> t) {
  final b = StringBuffer()
    ..writeln(
      '// Сгенерировано tool/gen_design_tokens.dart из design/tokens.json.',
    )
    ..writeln('// Не редактируйте вручную.')
    ..writeln()
    ..writeln('import SwiftUI')
    ..writeln();

  final color = t['color'] as Map<String, dynamic>;
  b.writeln('public enum GColor {');
  for (final group in ['brand', 'text', 'status']) {
    final entries = color[group] as Map<String, dynamic>;
    for (final MapEntry(:key, :value) in entries.entries) {
      final v = value as Map<String, dynamic>;
      b.writeln(
        '    public static let ${_camel(group, key)} = ${_dynamic(v['dark'], v['light'])}',
      );
    }
  }
  final ping = color['ping'] as Map<String, dynamic>;
  final unknown = ping['unknown'] as Map<String, dynamic>;
  b
    ..writeln(
      '    public static let pingUnknown = ${_dynamic(unknown['dark'], unknown['light'])}',
    )
    ..writeln('    public static let pingGoodBelowMs = ${ping['goodBelowMs']}')
    ..writeln('    public static let pingFairBelowMs = ${ping['fairBelowMs']}');
  final categories = color['settingsCategory'] as Map<String, dynamic>;
  for (final MapEntry(:key, :value) in categories.entries) {
    b.writeln(
      '    public static let ${_camel('category', key)} = ${_dynamic(value, value)}',
    );
  }
  b
    ..writeln('}')
    ..writeln();

  final glass =
      (t['material'] as Map<String, dynamic>)['glass'] as Map<String, dynamic>;
  final dark = glass['dark'] as Map<String, dynamic>;
  final light = glass['light'] as Map<String, dynamic>;
  b.writeln(
    '/// Заливки — запасной вариант для «Снизить прозрачность» и мест без стекла.',
  );
  b.writeln('public enum GMaterial {');
  for (final key in dark.keys) {
    b.writeln(
      '    public static let $key = ${_dynamic(dark[key], light[key])}',
    );
  }
  b
    ..writeln('}')
    ..writeln();

  final radius =
      (t['radius'] as Map<String, dynamic>)['glass'] as Map<String, dynamic>;
  b.writeln('public enum GRadius {');
  for (final MapEntry(:key, :value) in radius.entries) {
    b.writeln('    public static let $key: CGFloat = $value');
  }
  b
    ..writeln('}')
    ..writeln();

  final spacing = t['spacing'] as Map<String, dynamic>;
  b.writeln('public enum GSpacing {');
  for (final MapEntry(:key, :value) in spacing.entries) {
    b.writeln('    public static let $key: CGFloat = $value');
  }
  b
    ..writeln('}')
    ..writeln();

  final layout = t['layout'] as Map<String, dynamic>;
  final window = layout['window'] as Map<String, dynamic>;
  final sidebar = layout['sidebar'] as Map<String, dynamic>;
  final hit = layout['minHitTarget'] as Map<String, dynamic>;
  b
    ..writeln('public enum GLayout {')
    ..writeln(
      '    public static let windowDefaultWidth: CGFloat = ${window['defaultWidth']}',
    )
    ..writeln(
      '    public static let windowDefaultHeight: CGFloat = ${window['defaultHeight']}',
    )
    ..writeln(
      '    public static let windowMinWidth: CGFloat = ${window['minWidth']}',
    )
    ..writeln(
      '    public static let windowMinHeight: CGFloat = ${window['minHeight']}',
    )
    ..writeln(
      '    public static let sidebarMinWidth: CGFloat = ${sidebar['minWidth']}',
    )
    ..writeln(
      '    public static let sidebarMaxWidth: CGFloat = ${sidebar['maxWidth']}',
    )
    ..writeln(
      '    public static let sidebarFraction: CGFloat = ${sidebar['fractionOfWindow']}',
    )
    ..writeln(
      '    public static let sidebarHeaderHeight: CGFloat = ${layout['sidebarHeaderHeight']}',
    )
    ..writeln(
      '    public static let trafficLightsWidth: CGFloat = ${layout['trafficLightsWidth']}',
    )
    ..writeln('    public static let minHitTarget: CGFloat = ${hit['macos']}')
    ..writeln('}')
    ..writeln();

  final component = t['component'] as Map<String, dynamic>;
  b.writeln('public enum GComponent {');
  for (final MapEntry(:key, :value) in component.entries) {
    if (value is num) {
      b.writeln('    public static let $key: CGFloat = $value');
    } else if (value is Map<String, dynamic>) {
      for (final MapEntry(key: sub, value: v) in value.entries) {
        b.writeln('    public static let ${_camel(key, sub)}: CGFloat = $v');
      }
    }
  }
  b
    ..writeln('}')
    ..writeln();

  final globe = t['globe'] as Map<String, dynamic>;
  b.writeln('/// Планета: физика вращения, геометрия и цвета.');
  b.writeln('public enum GGlobe {');
  for (final MapEntry(:key, :value) in globe.entries) {
    if (value is num) {
      final type = key == 'samples' ? 'Int' : 'Double';
      b.writeln('    public static let $key: $type = $value');
    } else if (key == 'rate') {
      for (final MapEntry(key: sub, value: v) in (value as Map<String, dynamic>).entries) {
        b.writeln('    public static let ${_camel('rate', sub)}: Double = $v');
      }
    } else if (key == 'color') {
      final c = value as Map<String, dynamic>;
      final dark = c['dark'] as Map<String, dynamic>;
      final light = c['light'] as Map<String, dynamic>;
      for (final name in dark.keys) {
        if (dark[name] is num) {
          b.writeln(
            '    public static let ${name}Opacity = DynamicValue(dark: ${dark[name]}, light: ${light[name]})',
          );
        } else {
          b.writeln(
            '    public static let ${name}Color = ${_dynamic(dark[name], light[name])}',
          );
        }
      }
    }
  }
  b
    ..writeln('}')
    ..writeln();

  final typography = t['typography'] as Map<String, dynamic>;
  final body = (typography['bodySize'] as Map<String, dynamic>)['macos'];
  final scale = typography['scale'] as Map<String, dynamic>;
  b.writeln('public enum GType {');
  for (final MapEntry(:key, :value) in scale.entries) {
    final s = value as Map<String, dynamic>;
    final size = s['size'] == 'body' ? body : s['size'];
    b.writeln(
      '    public static let $key = TypeStyle(size: $size, weight: ${_weight(s['weight'] as int)}, tracking: ${s['tracking']}, lineHeight: ${s['lineHeight']})',
    );
  }
  b
    ..writeln('}')
    ..writeln();

  final motion = t['motion'] as Map<String, dynamic>;
  final springs = motion['springs'] as Map<String, dynamic>;
  final inertia = motion['inertia'] as Map<String, dynamic>;
  final rate = inertia['decelerationRate'] as Map<String, dynamic>;
  final press = motion['press'] as Map<String, dynamic>;
  final timing = motion['timing'] as Map<String, dynamic>;
  b.writeln('public enum GMotion {');
  for (final MapEntry(:key, :value) in springs.entries) {
    final s = value as Map<String, dynamic>;
    b.writeln(
      '    public static let $key = SpringToken(response: ${s['response']}, bounce: ${s['bounce']})',
    );
  }
  b
    ..writeln(
      '    public static let decelerationNormal: Double = ${rate['normal']}',
    )
    ..writeln(
      '    public static let decelerationFast: Double = ${rate['fast']}',
    )
    ..writeln(
      '    public static let rubberBandCoefficient: CGFloat = ${(motion['rubberBand'] as Map<String, dynamic>)['coefficient']}',
    )
    ..writeln(
      '    public static let pressScaleButton: CGFloat = ${press['scaleButton']}',
    )
    ..writeln(
      '    public static let pressScaleSmallControl: CGFloat = ${press['scaleSmallControl']}',
    )
    ..writeln(
      '    public static let pressScaleCard: CGFloat = ${press['scaleCard']}',
    )
    ..writeln(
      '    public static let breatheScale: CGFloat = ${motion['breatheScale']}',
    )
    ..writeln(
      '    public static let tooltipDelay: Duration = .milliseconds(${timing['tooltipDelayMs']})',
    )
    ..writeln(
      '    public static let toastBase: Duration = .milliseconds(${timing['toastBaseMs']})',
    )
    ..writeln(
      '    public static let toastPerWord: Duration = .milliseconds(${timing['toastPerWordMs']})',
    )
    ..writeln(
      '    public static let toastMax: Duration = .milliseconds(${timing['toastMaxMs']})',
    )
    ..writeln('}');
  return b.toString();
}

String _camel(String group, String key) =>
    '$group${key[0].toUpperCase()}${key.substring(1)}';

/// "#RRGGBB" или "#RRGGBB/альфа" → `DynamicColor(dark:…, light:…)`.
String _dynamic(Object? dark, Object? light) =>
    'DynamicColor(dark: ${_rgba(dark as String)}, light: ${_rgba(light as String)})';

String _rgba(String value) {
  final parts = value.split('/');
  final hex = parts[0].replaceFirst('#', '');
  final alpha = parts.length > 1 ? parts[1] : '1';
  return 'RGBA(0x$hex, $alpha)';
}

String _weight(int weight) => switch (weight) {
  >= 700 => '.bold',
  >= 600 => '.semibold',
  >= 500 => '.medium',
  _ => '.regular',
};
