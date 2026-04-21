import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

class ZapretPage extends ConsumerStatefulWidget {
  const ZapretPage({
    super.key,
    this.animateOnMount = true,
    this.contentPadding = EdgeInsets.zero,
  });

  final bool animateOnMount;
  final EdgeInsets contentPadding;

  @override
  ConsumerState<ZapretPage> createState() => _ZapretPageState();
}

class _ZapretPageState extends ConsumerState<ZapretPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _backgroundController;

  @override
  void initState() {
    super.initState();
    _backgroundController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();
  }

  @override
  void dispose() {
    _backgroundController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(zapretControllerProvider);

    final body = LayoutBuilder(
      builder: (context, constraints) {
        final layout = _ZapretBoostLayout.fromConstraints(constraints);
        final content = SizedBox(
          key: const ValueKey('zapret-boost-scene'),
          width: layout.sceneWidth,
          height: layout.sceneHeight,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              widget.contentPadding.left + layout.horizontalPadding,
              widget.contentPadding.top + layout.verticalPadding,
              widget.contentPadding.right + layout.horizontalPadding,
              widget.contentPadding.bottom + layout.verticalPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.center,
                    child: _buildHero(context, state, layout),
                  ),
                ),
                SizedBox(height: layout.sectionGap),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: layout.cardWidth),
                    child: _buildControlCard(context, state, layout),
                  ),
                ),
              ],
            ),
          ),
        );

        return SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _BoostAnimatedBackdrop(animation: _backgroundController),
              if (layout.scaleFallback)
                FittedBox(
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  child: content,
                )
              else
                content,
            ],
          ),
        );
      },
    );

    return widget.animateOnMount
        ? PageReveal(
            duration: const Duration(milliseconds: 220),
            offset: const Offset(0, 0.02),
            child: body,
          )
        : body;
  }

  Widget _buildHero(
    BuildContext context,
    ZapretState state,
    _ZapretBoostLayout layout,
  ) {
    final theme = Theme.of(context);
    const textAlign = TextAlign.center;
    const crossAxisAlignment = CrossAxisAlignment.center;
    final recommendationButton = _BoostRecommendationButton(
      accentColor: theme.brandAccent,
      compact: layout.compact,
      inProgress: state.configTestInProgress,
      progressValue: state.configTestTotal <= 0
          ? null
          : state.configTestCompleted / state.configTestTotal,
      progressLabel: _httpTestProgressLabel(state),
      statusMessage: _recommendationStatusText(state),
      statusColor: _recommendationStatusColor(theme, state),
      reportButton: state.configTestSuite == null
          ? null
          : _ActionIconButton(
              tooltip: 'Подробный отчёт',
              icon: Icons.insights_rounded,
              color: theme.brandAccent,
              onPressed: () => _showHttpTestReport(state.configTestSuite!),
            ),
      onPressed: state.busy ? null : _handleRecommendationTap,
    );

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: layout.heroWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: crossAxisAlignment,
          children: [
            Text(
              'Gorion Boost',
              textAlign: textAlign,
              style: theme.textTheme.displayLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontSize: layout.titleFontSize,
                fontWeight: FontWeight.w700,
                height: 0.94,
                letterSpacing: -2.4,
                shadows: [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 28,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
            ),
            SizedBox(height: layout.heroSpacing),
            Text(
              _heroSubtitle(state),
              textAlign: textAlign,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.gorionTokens.onSurfaceMuted.withValues(
                  alpha: 0.96,
                ),
                fontSize: layout.subtitleFontSize,
                fontWeight: FontWeight.w500,
                height: 1.42,
              ),
            ),
            SizedBox(height: layout.heroSpacing),
            recommendationButton,
          ],
        ),
      ),
    );
  }

  Widget _buildControlCard(
    BuildContext context,
    ZapretState state,
    _ZapretBoostLayout layout,
  ) {
    final theme = Theme.of(context);
    final controller = ref.read(zapretControllerProvider.notifier);
    final stageColor = _stageColor(theme, state.stage);
    final selectedConfigLabel = state.availableConfigs.isEmpty
        ? 'Конфиги не найдены'
        : state.settings.effectiveConfigLabel;

    return GlassPanel(
      borderRadius: layout.cardRadius,
      padding: EdgeInsets.all(layout.cardPadding),
      opacity: 0.08,
      backgroundColor: Colors.white,
      strokeColor: stageColor,
      strokeOpacity: 0.14,
      strokeWidth: 1,
      showGlow: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < 820;
          final actionGap = layout.compact ? 6.0 : 8.0;

          final gameFilterBlock = _ControlBlock(
            title: 'GameFilter',
            accentColor: const Color(0xFF72A8FF),
            trailing: _MetaPill(
              label: state.settings.gameFilterMode.label,
              color: state.settings.gameFilterEnabled
                  ? const Color(0xFF72A8FF)
                  : theme.gorionTokens.onSurfaceMuted,
              compact: layout.ultraCompact,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    state.settings.gameFilterEnabled
                        ? 'Фильтр добавится в команду запуска. Текущий режим: ${state.settings.gameFilterMode.label}.'
                        : 'Boost запустится без дополнительного фильтра. Включи тумблер, если он нужен.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.gorionTokens.onSurfaceMuted,
                      fontSize: layout.compact ? 13 : 14,
                      height: 1.42,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Switch.adaptive(
                  value: state.settings.gameFilterEnabled,
                  onChanged: state.busy
                      ? null
                      : (value) => controller.setGameFilterEnabled(value),
                ),
              ],
            ),
          );

          final configBlock = _ControlBlock(
            title: 'Выбранный конфиг',
            accentColor: theme.brandAccent,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ActionIconButton(
                  tooltip: 'Обновить конфиги',
                  icon: Icons.refresh_rounded,
                  color: theme.brandAccent,
                  onPressed: state.busy ? null : _refreshConfigs,
                ),
                SizedBox(width: actionGap),
                _ActionIconButton(
                  tooltip: 'Открыть папку конфигов',
                  icon: Icons.folder_open_rounded,
                  color: const Color(0xFFFFB457),
                  onPressed: state.busy ? null : _openProfilesFolder,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PopupMenuButton<String>(
                  enabled: !state.busy && state.availableConfigs.isNotEmpty,
                  tooltip: 'Выбрать конфиг',
                  onSelected: controller.setConfigFileName,
                  itemBuilder: (context) => [
                    for (final option in state.availableConfigs)
                      PopupMenuItem<String>(
                        value: option.fileName,
                        child: Text(option.label),
                      ),
                  ],
                  child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                      horizontal: layout.compact ? 14 : 16,
                      vertical: layout.compact ? 13 : 14,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.34),
                      border: Border.all(
                        color: theme.brandAccent.withValues(
                          alpha: state.availableConfigs.isEmpty ? 0.08 : 0.18,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            selectedConfigLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: state.availableConfigs.isEmpty
                                  ? theme.gorionTokens.onSurfaceMuted
                                  : theme.colorScheme.onSurface,
                              fontSize: layout.compact ? 17 : 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: state.availableConfigs.isEmpty
                              ? theme.gorionTokens.onSurfaceMuted
                              : theme.brandAccent,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Подключение Boost',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontSize: layout.compact ? 24 : 28,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Один блок для запуска, статуса и выбора своего конфига без дополнительных карточек.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.gorionTokens.onSurfaceMuted,
                            fontSize: layout.compact ? 13 : 14,
                            height: 1.42,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: layout.sectionGap),
                  _ZapretPowerButton(
                    stage: state.stage,
                    enabled: state.canStart || state.canStop,
                    compact: constraints.maxWidth < 560,
                    onTap:
                        state.stage == ZapretStage.starting ||
                            state.stage == ZapretStage.stopping
                        ? null
                        : state.canStop
                        ? () => controller.stop()
                        : state.canStart
                        ? () => controller.start()
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 30),
              if (stacked) ...[
                configBlock,
                SizedBox(height: layout.sectionGap),
                gameFilterBlock,
              ] else
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 5, child: gameFilterBlock),
                      SizedBox(width: layout.sectionGap),
                      Expanded(flex: 7, child: configBlock),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _refreshConfigs() async {
    await ref.read(zapretControllerProvider.notifier).refreshConfigs();
  }

  Future<void> _openProfilesFolder() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final folderPath = await ref
        .read(zapretControllerProvider.notifier)
        .prepareProfilesDirectory();
    if (!mounted) {
      return;
    }
    if (folderPath == null || folderPath.trim().isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Не удалось подготовить папку профилей Boost.'),
        ),
      );
      return;
    }

    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [
          folderPath,
        ], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [
          folderPath,
        ], mode: ProcessStartMode.detached);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [
          folderPath,
        ], mode: ProcessStartMode.detached);
      } else {
        throw UnsupportedError('Открытие папки не поддерживается.');
      }
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Не удалось открыть папку: $error')),
      );
    }
  }

  Future<void> _runHttpConfigTests() async {
    await ref.read(zapretControllerProvider.notifier).runHttpConfigTests();
  }

  Future<void> _handleRecommendationTap() async {
    final dashboardState = ref.read(dashboardControllerProvider);
    final connectionStage = dashboardState.connectionStage;
    final vpnActive =
        connectionStage == ConnectionStage.connected ||
        connectionStage == ConnectionStage.starting;

    if (connectionStage == ConnectionStage.stopping) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Сначала дождитесь завершения отключения VPN, затем повторите подбор.',
          ),
        ),
      );
      return;
    }

    if (vpnActive) {
      final shouldDisconnect = await _showRecommendationDisconnectWarning(
        dashboardState.runtimeMode.label,
      );
      if (!shouldDisconnect || !mounted) {
        return;
      }

      await ref.read(dashboardControllerProvider.notifier).disconnect();
      if (!mounted) {
        return;
      }

      final nextStage = ref.read(dashboardControllerProvider).connectionStage;
      if (nextStage != ConnectionStage.disconnected) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось отключить VPN перед тестом Boost. Повторите попытку.',
            ),
          ),
        );
        return;
      }
    }

    await _runHttpConfigTests();
  }

  Future<bool> _showRecommendationDisconnectWarning(String modeLabel) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          backgroundColor: theme.colorScheme.surface,
          title: Text(
            'Отключить VPN перед тестом?',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            'Сейчас активен VPN в режиме $modeLabel. Для чистоты теста Boost он будет отключён перед подбором рекомендуемого конфига.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.gorionTokens.onSurfaceMuted,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Отключить и продолжить'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _showHttpTestReport(ZapretConfigTestSuite suite) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return _HttpTestReportDialog(
          suite: suite,
          testResultColor: _testResultColor,
        );
      },
    );
  }

  Color _stageColor(ThemeData theme, ZapretStage stage) {
    return switch (stage) {
      ZapretStage.running => const Color(0xFF1EFFAC),
      ZapretStage.starting || ZapretStage.stopping => const Color(0xFFFFB457),
      ZapretStage.pausedByTun => const Color(0xFF72A8FF),
      ZapretStage.failed || ZapretStage.stopped => const Color(0xFFFF6B6B),
    };
  }

  String _heroSubtitle(ZapretState state) {
    if (!Platform.isWindows) {
      return 'Gorion Boost сейчас работает только в Windows.';
    }
    if (state.tunConflictActive) {
      return 'TUN-режим sing-box активен, поэтому запуск Boost временно заблокирован.';
    }
    return 'Улучшай связь и загрузку видео без смены сети: выбирай конфиг и управляй Boost в этом разделе.';
  }

  String _httpTestProgressLabel(ZapretState state) {
    final current = state.configTestCurrentConfigLabel;
    final progress = '${state.configTestCompleted}/${state.configTestTotal}';
    if (current == null || current.isEmpty) {
      return 'Подготавливаем подбор • $progress';
    }
    return 'Проверяем $current • $progress';
  }

  String? _recommendationStatusText(ZapretState state) {
    if (state.errorMessage case final errorMessage?) {
      return errorMessage;
    }

    final suite = state.configTestSuite;
    final bestWorking = suite?.bestWorkingResult;
    if (suite != null) {
      if (bestWorking != null) {
        final statusMessage = state.statusMessage?.trim().toLowerCase();
        final prefix =
            statusMessage != null && statusMessage.contains('уже был выбран')
            ? 'Лучший конфиг уже выбран'
            : 'Выбран';
        return '$prefix: ${bestWorking.config.label}';
      }
      return suite.summary;
    }

    final statusMessage = state.statusMessage?.trim();
    if (statusMessage == null || statusMessage.isEmpty) {
      return null;
    }
    if (state.stage == ZapretStage.running) {
      return null;
    }
    return statusMessage;
  }

  Color _recommendationStatusColor(ThemeData theme, ZapretState state) {
    if (state.errorMessage != null) {
      return const Color(0xFFFF8A8A);
    }
    if (state.configTestSuite != null) {
      return state.configTestSuite?.bestWorkingResult == null
          ? const Color(0xFFFFC680)
          : theme.brandAccent;
    }
    return theme.gorionTokens.onSurfaceMuted;
  }

  Color _testResultColor(ZapretConfigTestResult result) {
    if (result.fullyWorking) {
      return const Color(0xFF1EFFAC);
    }
    if (!result.launchSucceeded || result.failedTesting) {
      return const Color(0xFFFF8A8A);
    }
    return const Color(0xFFFFC680);
  }
}

class _ZapretBoostLayout {
  const _ZapretBoostLayout({
    required this.compact,
    required this.ultraCompact,
    required this.scaleFallback,
    required this.sceneWidth,
    required this.sceneHeight,
    required this.heroWidth,
    required this.cardWidth,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.cardPadding,
    required this.cardRadius,
    required this.sectionGap,
    required this.titleFontSize,
    required this.subtitleFontSize,
    required this.heroSpacing,
  });

  factory _ZapretBoostLayout.fromConstraints(BoxConstraints constraints) {
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 1280.0;
    final height = constraints.hasBoundedHeight ? constraints.maxHeight : 820.0;
    final compact = width < 980 || height < 680;
    final ultraCompact = width < 760 || height < 520;
    final scaleFallback = width < 1500 || height < 940;
    final sceneWidth = scaleFallback ? 1360.0 : width;
    final sceneHeight = scaleFallback ? 1000.0 : height;

    return _ZapretBoostLayout(
      compact: compact,
      ultraCompact: ultraCompact,
      scaleFallback: scaleFallback,
      sceneWidth: sceneWidth,
      sceneHeight: sceneHeight,
      heroWidth: compact ? 620.0 : 860.0,
      cardWidth: compact ? math.min(sceneWidth, 920.0) : 1040.0,
      horizontalPadding: ultraCompact
          ? 20
          : compact
          ? 28
          : 40,
      verticalPadding: ultraCompact
          ? 18
          : compact
          ? 24
          : 36,
      cardPadding: ultraCompact
          ? 18
          : compact
          ? 22
          : 26,
      cardRadius: ultraCompact
          ? 24
          : compact
          ? 28
          : 32,
      sectionGap: ultraCompact
          ? 12
          : compact
          ? 16
          : 20,
      titleFontSize: ultraCompact
          ? 44
          : compact
          ? 56
          : 82,
      subtitleFontSize: ultraCompact
          ? 14
          : compact
          ? 16
          : 18,
      heroSpacing: ultraCompact
          ? 14
          : compact
          ? 18
          : 22,
    );
  }

  final bool compact;
  final bool ultraCompact;
  final bool scaleFallback;
  final double sceneWidth;
  final double sceneHeight;
  final double heroWidth;
  final double cardWidth;
  final double horizontalPadding;
  final double verticalPadding;
  final double cardPadding;
  final double cardRadius;
  final double sectionGap;
  final double titleFontSize;
  final double subtitleFontSize;
  final double heroSpacing;
}

class _BoostAnimatedBackdrop extends StatelessWidget {
  const _BoostAnimatedBackdrop({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: CustomPaint(
        painter: _DottedSurfacePainter(
          animation: animation,
          brightness: theme.brightness,
        ),
      ),
    );
  }
}

class _DottedSurfacePainter extends CustomPainter {
  _DottedSurfacePainter({required this.animation, required this.brightness})
    : super(repaint: animation);

  final Animation<double> animation;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }

    const separation = 150.0;
    const amountX = 40;
    const amountY = 60;
    const fov = 60.0;
    const cameraX = 0.0;
    const cameraY = 355.0;
    const cameraZ = 1220.0;
    const fogNear = 2000.0;
    const fogFar = 10000.0;
    const pointSize = 8.0;

    final isDark = brightness == Brightness.dark;
    final baseColor = isDark
        ? const Color.fromARGB(255, 200, 200, 200)
        : const Color.fromARGB(255, 0, 0, 0);
    const fogColor = Colors.white;
    final focalLength = size.height / 2 / math.tan(fov * math.pi / 360);
    final phase = animation.value * math.pi * 2;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    for (var ix = 0; ix < amountX; ix += 1) {
      for (var iy = 0; iy < amountY; iy += 1) {
        final worldX = ix * separation - (amountX * separation) / 2;
        // Use loop-safe phases so the last frame matches the first one exactly.
        final worldY =
            math.sin(ix * 0.3 + phase * 3) * 50 +
            math.sin(iy * 0.5 + phase * 5) * 50;
        final worldZ = iy * separation - (amountY * separation) / 2;

        final cameraSpaceX = worldX - cameraX;
        final cameraSpaceY = worldY - cameraY;
        final cameraSpaceZ = worldZ - cameraZ;
        if (cameraSpaceZ >= -1) {
          continue;
        }

        final depth = -cameraSpaceZ;
        final projectedX = size.width / 2 + cameraSpaceX * focalLength / depth;
        final projectedY = size.height / 2 - cameraSpaceY * focalLength / depth;
        if (projectedX < -32 ||
            projectedX > size.width + 32 ||
            projectedY < -32 ||
            projectedY > size.height + 32) {
          continue;
        }

        final fogFactor = ((depth - fogNear) / (fogFar - fogNear)).clamp(
          0.0,
          1.0,
        );
        final color = Color.lerp(baseColor, fogColor, fogFactor * 0.85)!;
        final sizePx = pointSize * focalLength / depth;
        final radius = (sizePx * 0.5).clamp(0.35, 3.8);
        paint.color = color.withValues(
          alpha: isDark
              ? (0.82 - fogFactor * 0.18).clamp(0.0, 1.0)
              : (0.74 - fogFactor * 0.28).clamp(0.0, 1.0),
        );
        canvas.drawCircle(Offset(projectedX, projectedY), radius, paint);
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DottedSurfacePainter oldDelegate) {
    return oldDelegate.animation != animation ||
        oldDelegate.brightness != brightness;
  }
}

class _ControlBlock extends StatelessWidget {
  const _ControlBlock({
    required this.title,
    required this.accentColor,
    required this.child,
    this.trailing,
  });

  final String title;
  final Color accentColor;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: accentColor.withValues(alpha: 0.08),
        border: Border.all(color: accentColor.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _ZapretPowerButton extends StatelessWidget {
  const _ZapretPowerButton({
    required this.stage,
    required this.enabled,
    required this.compact,
    required this.onTap,
  });

  final ZapretStage stage;
  final bool enabled;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final baseColor = switch (stage) {
      ZapretStage.running => const Color(0xFF1EFFAC),
      ZapretStage.starting || ZapretStage.stopping => const Color(0xFFFFB457),
      ZapretStage.pausedByTun => const Color(0xFF72A8FF),
      ZapretStage.failed || ZapretStage.stopped => const Color(0xFFFF6B6B),
    };
    final color =
        enabled ||
            stage == ZapretStage.starting ||
            stage == ZapretStage.stopping
        ? baseColor
        : baseColor.withValues(alpha: 0.52);
    final size = compact ? 56.0 : 64.0;

    return MouseRegion(
      cursor: onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(compact ? 16 : 18),
            color: color.withValues(alpha: 0.12),
            border: Border.all(color: color.withValues(alpha: 0.62)),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.14),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: stage == ZapretStage.starting || stage == ZapretStage.stopping
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: compact ? 22 : 26,
                      height: compact ? 22 : 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color.withValues(alpha: 0.96),
                      ),
                    ),
                    Icon(
                      Icons.close_rounded,
                      size: compact ? 14 : 16,
                      color: color,
                    ),
                  ],
                )
              : SvgPicture.asset(
                  'assets/images/power.svg',
                  width: compact ? 22 : 26,
                  height: compact ? 22 : 26,
                  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                ),
        ),
      ),
    );
  }
}

class _BoostRecommendationButton extends StatelessWidget {
  const _BoostRecommendationButton({
    required this.accentColor,
    required this.compact,
    required this.inProgress,
    required this.progressValue,
    required this.progressLabel,
    required this.statusColor,
    required this.onPressed,
    this.statusMessage,
    this.reportButton,
  });

  final Color accentColor;
  final bool compact;
  final bool inProgress;
  final double? progressValue;
  final String progressLabel;
  final String? statusMessage;
  final Color statusColor;
  final Widget? reportButton;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttonHeight = compact ? 44.0 : 48.0;
    final buttonWidth = compact ? 320.0 : 420.0;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: compact ? 560 : 640),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: FilledButton.icon(
                  onPressed: onPressed,
                  icon: inProgress
                      ? SizedBox(
                          width: compact ? 14 : 16,
                          height: compact ? 14 : 16,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2.1,
                          ),
                        )
                      : const Icon(Icons.auto_awesome_rounded),
                  label: Text(
                    inProgress
                        ? 'Подбираем рекомендуемый'
                        : 'Подобрать рекомендуемый',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: Size(buttonWidth, buttonHeight),
                    backgroundColor: accentColor,
                    foregroundColor: const Color(0xFF03211B),
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 14 : 18,
                      vertical: compact ? 12 : 13,
                    ),
                    textStyle: theme.textTheme.labelLarge?.copyWith(
                      fontSize: compact ? 13 : 14,
                      fontWeight: FontWeight.w700,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
              if (reportButton != null) ...[
                const SizedBox(width: 10),
                reportButton!,
              ],
            ],
          ),
          if (inProgress) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: buttonWidth,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progressValue,
                  minHeight: 4,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.28),
                  valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              progressLabel,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.gorionTokens.onSurfaceMuted,
                fontSize: compact ? 12 : 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else if (statusMessage case final text?) ...[
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: statusColor,
                fontSize: compact ? 13 : 14,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HttpTestReportDialog extends StatefulWidget {
  const _HttpTestReportDialog({
    required this.suite,
    required this.testResultColor,
  });

  final ZapretConfigTestSuite suite;
  final Color Function(ZapretConfigTestResult result) testResultColor;

  @override
  State<_HttpTestReportDialog> createState() => _HttpTestReportDialogState();
}

class _HttpTestReportDialogState extends State<_HttpTestReportDialog> {
  final Set<String> _expandedGroups = <String>{};
  bool _summaryExpanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summaryColor = widget.suite.bestWorkingResult == null
        ? const Color(0xFFFFC680)
        : const Color(0xFF1EFFAC);

    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      title: Text(
        'Отчёт стандартного теста',
        style: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ReportSummaryPanel(
                title: 'Сводка теста',
                expanded: _summaryExpanded,
                accentColor: summaryColor,
                onToggle: () {
                  setState(() {
                    _summaryExpanded = !_summaryExpanded;
                  });
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.suite.summary,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Файл целей: ${widget.suite.targetsPath}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.gorionTokens.onSurfaceMuted,
                        height: 1.35,
                      ),
                    ),
                    if (widget.suite.ignoredTargetCount > 0) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Пропущено не-HTTP целей: ${widget.suite.ignoredTargetCount}.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.gorionTokens.onSurfaceMuted,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              for (final result in widget.suite.results) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.24,
                    ),
                    border: Border.all(
                      color: widget
                          .testResultColor(result)
                          .withValues(alpha: 0.24),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              result.config.label,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          _MetaPill(
                            label: result.fullyWorking
                                ? 'Полностью ок'
                                : result.failedTesting
                                ? 'Провал'
                                : result.launchSucceeded
                                ? 'Частично'
                                : 'Не запустился',
                            color: widget.testResultColor(result),
                            compact: false,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        result.summary,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.gorionTokens.onSurfaceMuted,
                          height: 1.42,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final group in _groupProbeResults(
                        result.report.results,
                      ))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _ReportProbeGroupPanel(
                            group: group,
                            expanded: _expandedGroups.contains(
                              '${result.config.fileName}:${group.title}',
                            ),
                            onToggle: () {
                              final key =
                                  '${result.config.fileName}:${group.title}';
                              setState(() {
                                if (!_expandedGroups.add(key)) {
                                  _expandedGroups.remove(key);
                                }
                              });
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

class _ReportSummaryPanel extends StatelessWidget {
  const _ReportSummaryPanel({
    required this.title,
    required this.expanded,
    required this.accentColor,
    required this.onToggle,
    required this.child,
  });

  final String title;
  final bool expanded;
  final Color accentColor;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: accentColor.withValues(alpha: 0.08),
        border: Border.all(color: accentColor.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: accentColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: accentColor,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: child,
            ),
        ],
      ),
    );
  }
}

class _ReportProbeGroupPanel extends StatelessWidget {
  const _ReportProbeGroupPanel({
    required this.group,
    required this.expanded,
    required this.onToggle,
  });

  final _ProbeResultGroup group;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allRequiredPassed =
        group.requiredTotal == 0 || group.requiredPassed == group.requiredTotal;
    final accentColor = allRequiredPassed
        ? const Color(0xFF1EFFAC)
        : const Color(0xFFFFC680);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: accentColor.withValues(alpha: 0.06),
        border: Border.all(color: accentColor.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      group.title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _MetaPill(
                    label: '${group.requiredPassed}/${group.requiredTotal}',
                    color: accentColor,
                    compact: true,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: accentColor,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final probe in group.probes)
                    _MetaPill(
                      label: _probeResultPillLabel(probe),
                      color: probe.success
                          ? const Color(0xFF1EFFAC)
                          : const Color(0xFFFF8A8A),
                      compact: false,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ProbeResultGroup {
  const _ProbeResultGroup({
    required this.title,
    required this.probes,
    required this.requiredPassed,
    required this.requiredTotal,
  });

  final String title;
  final List<ZapretProbeResult> probes;
  final int requiredPassed;
  final int requiredTotal;
}

class _ActionIconButton extends StatelessWidget {
  const _ActionIconButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: color.withValues(alpha: enabled ? 0.12 : 0.06),
              border: Border.all(
                color: color.withValues(alpha: enabled ? 0.22 : 0.10),
              ),
            ),
            child: Icon(
              icon,
              size: 20,
              color: enabled ? color : color.withValues(alpha: 0.46),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({
    required this.label,
    required this.color,
    this.compact = false,
  });

  final String label;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelLarge?.copyWith(
          color: color,
          fontSize: compact ? 12 : 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

List<_ProbeResultGroup> _groupProbeResults(List<ZapretProbeResult> probes) {
  final grouped = <String, List<ZapretProbeResult>>{};
  for (final probe in probes) {
    final key = _probeGroupTitle(probe.target.label);
    grouped.putIfAbsent(key, () => <ZapretProbeResult>[]).add(probe);
  }

  return grouped.entries
      .map((entry) {
        final requiredProbes = entry.value
            .where((probe) => probe.target.requiredForSuccess)
            .toList(growable: false);
        final requiredPassed = requiredProbes
            .where((probe) => probe.success)
            .length;
        return _ProbeResultGroup(
          title: entry.key,
          probes: entry.value,
          requiredPassed: requiredPassed,
          requiredTotal: requiredProbes.length,
        );
      })
      .toList(growable: false);
}

String _probeGroupTitle(String label) {
  const suffixes = <String>[
    ' HTTP/1.1 GET',
    ' TLS 1.2 GET',
    ' TLS 1.3 GET',
    ' HTTP/1.1',
    ' TLS 1.2',
    ' TLS 1.3',
    ' WebSocket',
    ' Ping',
  ];

  for (final suffix in suffixes) {
    if (label.endsWith(suffix)) {
      return label.substring(0, label.length - suffix.length).trim();
    }
  }
  return label;
}

String _probeShortLabel(String label) {
  final groupTitle = _probeGroupTitle(label);
  if (groupTitle == label) {
    return label;
  }
  return label.substring(groupTitle.length).trim();
}

String _probeResultPillLabel(ZapretProbeResult probe) {
  final status = probe.success ? 'ok' : 'fail';
  final latency = probe.latencyMs == null ? '' : ' • ${probe.latencyMs} ms';
  return '${_probeShortLabel(probe.target.label)}: $status$latency';
}
