part of 'map_view.dart';

class _TrafficPanel extends StatelessWidget {
  const _TrafficPanel({
    required this.downlink,
    required this.uplink,
    required this.active,
    required this.accent,
  });

  final int downlink;
  final int uplink;
  final bool active;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final uploadAccent = theme.brightness == Brightness.dark
        ? const Color(0xFFFF7AA8)
        : const Color(0xFFC43C70);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 15, 18, 15),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.035 : 0.045,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: 0.07),
          width: 0.8,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 460;
          final graph = SizedBox(
            height: 52,
            child: _TrafficSparkline(
              active: active,
              downlink: downlink,
              uplink: uplink,
              accent: accent,
              uploadAccent: uploadAccent,
            ),
          );

          if (isCompact) {
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _TrafficValue(
                        icon: Icons.arrow_downward_rounded,
                        label: 'Загрузка',
                        value: _formatSpeed(downlink),
                        color: accent,
                      ),
                    ),
                    const Gap(12),
                    Expanded(
                      child: _TrafficValue(
                        icon: Icons.arrow_upward_rounded,
                        label: 'Отдача',
                        value: _formatSpeed(uplink),
                        color: uploadAccent,
                        alignEnd: true,
                      ),
                    ),
                  ],
                ),
                const Gap(10),
                graph,
              ],
            );
          }

          return Row(
            children: [
              SizedBox(
                width: 138,
                child: _TrafficValue(
                  icon: Icons.arrow_downward_rounded,
                  label: 'Загрузка',
                  value: _formatSpeed(downlink),
                  color: accent,
                ),
              ),
              const Gap(18),
              Expanded(child: graph),
              const Gap(18),
              SizedBox(
                width: 138,
                child: _TrafficValue(
                  icon: Icons.arrow_upward_rounded,
                  label: 'Отдача',
                  value: _formatSpeed(uplink),
                  color: uploadAccent,
                  alignEnd: true,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TrafficValue extends StatelessWidget {
  const _TrafficValue({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.alignEnd = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).gorionTokens.onSurfaceMuted;
    return LayoutBuilder(
      builder: (context, constraints) {
        final showIcon = constraints.maxWidth >= 48;
        final valueFontSize = constraints.maxWidth < 92 ? 16.0 : 22.0;

        return Column(
          crossAxisAlignment: alignEnd
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: alignEnd
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (showIcon) ...[
                  Icon(icon, size: 20, color: color),
                  const Gap(8),
                ],
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: valueFontSize,
                      fontWeight: FontWeight.w800,
                      height: 1,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
            const Gap(8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: muted.withValues(alpha: 0.88),
                fontSize: constraints.maxWidth < 92 ? 10.5 : 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        );
      },
    );
  }
}

const _trafficHistoryLength = 32;

class _TrafficSample {
  const _TrafficSample({required this.downlink, required this.uplink});

  final int downlink;
  final int uplink;
}

List<_TrafficSample> _emptyTrafficHistory() => List<_TrafficSample>.filled(
  _trafficHistoryLength,
  const _TrafficSample(downlink: 0, uplink: 0),
);

class _TrafficSparkline extends HookWidget {
  const _TrafficSparkline({
    required this.active,
    required this.downlink,
    required this.uplink,
    required this.accent,
    required this.uploadAccent,
  });

  final bool active;
  final int downlink;
  final int uplink;
  final Color accent;
  final Color uploadAccent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latestActive = useRef(active);
    final latestDownlink = useRef(downlink);
    final latestUplink = useRef(uplink);
    final samples = useState<List<_TrafficSample>>(_emptyTrafficHistory());

    void appendSample() {
      final sample = latestActive.value
          ? _TrafficSample(
              downlink: latestDownlink.value,
              uplink: latestUplink.value,
            )
          : const _TrafficSample(downlink: 0, uplink: 0);
      final next = [...samples.value, sample];
      if (next.length > _trafficHistoryLength) {
        next.removeRange(0, next.length - _trafficHistoryLength);
      }
      samples.value = List.unmodifiable(next);
    }

    useEffect(() {
      latestActive.value = active;
      latestDownlink.value = downlink;
      latestUplink.value = uplink;
      appendSample();
      return null;
    }, [active, downlink, uplink]);

    useEffect(() {
      final timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => appendSample(),
      );
      return timer.cancel;
    }, const []);

    return CustomPaint(
      painter: _TrafficSparklinePainter(
        samples: samples.value,
        accent: active
            ? accent
            : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.72),
        uploadAccent: active
            ? uploadAccent
            : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.58),
        muted: theme.gorionTokens.onSurfaceMuted,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _TrafficSparklinePainter extends CustomPainter {
  const _TrafficSparklinePainter({
    required this.samples,
    required this.accent,
    required this.uploadAccent,
    required this.muted,
  });

  final List<_TrafficSample> samples;
  final Color accent;
  final Color uploadAccent;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final baselineY = size.height - 7;
    final maxValue = samples.fold<int>(
      1,
      (current, sample) =>
          math.max(current, math.max(sample.downlink, sample.uplink)),
    );
    final downlinkPoints = _pointsForSeries(
      samples.map((sample) => sample.downlink).toList(growable: false),
      size,
      maxValue,
    );
    final uplinkPoints = _pointsForSeries(
      samples.map((sample) => sample.uplink).toList(growable: false),
      size,
      maxValue,
    );
    final downlinkPath = _smoothPath(downlinkPoints);
    final uplinkPath = _smoothPath(uplinkPoints);

    final fillPath = Path.from(downlinkPath)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, 0),
          Offset(0, size.height),
          [
            accent.withValues(alpha: 0.14),
            accent.withValues(alpha: 0.02),
            Colors.transparent,
          ],
          const [0.0, 0.72, 1.0],
        ),
    );

    canvas.drawLine(
      Offset(0, baselineY),
      Offset(size.width, baselineY),
      Paint()
        ..color = muted.withValues(alpha: 0.08)
        ..strokeWidth = 1,
    );

    canvas.drawPath(
      downlinkPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = accent.withValues(alpha: 0.11)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawPath(
      downlinkPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = accent.withValues(alpha: 0.78),
    );
    canvas.drawPath(
      uplinkPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = uploadAccent.withValues(alpha: 0.70),
    );
  }

  List<Offset> _pointsForSeries(List<int> values, Size size, int maxValue) {
    if (values.isEmpty) {
      return [Offset(0, size.height - 7), Offset(size.width, size.height - 7)];
    }

    final top = 5.0;
    final bottom = size.height - 7.0;
    final height = math.max(1.0, bottom - top);
    final denominator = math.max(1, maxValue).toDouble();
    return [
      for (var index = 0; index < values.length; index += 1)
        Offset(
          values.length == 1
              ? size.width
              : (index / (values.length - 1)) * size.width,
          bottom -
              ((values[index].clamp(0, maxValue) / denominator) * height).clamp(
                0.0,
                height,
              ),
        ),
    ];
  }

  Path _smoothPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index += 1) {
      final previous = points[index - 1];
      final current = points[index];
      final control = Offset((previous.dx + current.dx) / 2, previous.dy);
      final endControl = Offset((previous.dx + current.dx) / 2, current.dy);
      path.cubicTo(
        control.dx,
        control.dy,
        endControl.dx,
        endControl.dy,
        current.dx,
        current.dy,
      );
    }
    return path;
  }

  @override
  bool shouldRepaint(_TrafficSparklinePainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.accent != accent ||
      oldDelegate.uploadAccent != uploadAccent ||
      oldDelegate.muted != muted;
}
