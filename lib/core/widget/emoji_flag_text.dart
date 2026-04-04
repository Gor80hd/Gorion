import 'package:flutter/widgets.dart';

class EmojiFlagText extends StatelessWidget {
  const EmojiFlagText(
    this.text, {
    super.key,
    this.style,
    this.flagStyle,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.textAlign,
    this.softWrap,
  });

  final String text;
  final TextStyle? style;
  final TextStyle? flagStyle;
  final int? maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;
  final bool? softWrap;

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style.merge(style);
    final effectiveFlagStyle = baseStyle
        .copyWith(fontFamily: 'Emoji')
        .merge(flagStyle);

    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: _buildEmojiFlagSpans(text, effectiveFlagStyle),
      ),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      softWrap: softWrap,
    );
  }
}

List<InlineSpan> _buildEmojiFlagSpans(String text, TextStyle flagStyle) {
  final spans = <InlineSpan>[];
  var buffer = StringBuffer();
  final runes = text.runes.toList(growable: false);

  void flushBuffer() {
    if (buffer.length == 0) {
      return;
    }
    spans.add(TextSpan(text: buffer.toString()));
    buffer = StringBuffer();
  }

  for (var index = 0; index < runes.length; index += 1) {
    final current = runes[index];
    final next = index + 1 < runes.length ? runes[index + 1] : null;
    if (next != null && _isRegionalIndicator(current) && _isRegionalIndicator(next)) {
      flushBuffer();
      spans.add(
        TextSpan(
          text: String.fromCharCodes([current, next]),
          style: flagStyle,
        ),
      );
      index += 1;
      continue;
    }

    buffer.write(String.fromCharCode(current));
  }

  flushBuffer();
  return spans;
}

bool _isRegionalIndicator(int value) =>
    value >= 0x1F1E6 && value <= 0x1F1FF;