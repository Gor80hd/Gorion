import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';

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
    final bannerText = state.errorMessage ?? state.statusMessage;
    final bannerColor = state.errorMessage != null
        ? const Color(0xFFFF8A8A)
        : stageColor;
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

          final statusBlock = _ControlBlock(
            title: 'Статус работы',
            accentColor: bannerColor,
            trailing: _MetaPill(
              label: state.stage.label,
              color: bannerColor,
              compact: layout.ultraCompact,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusHeadline(state),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontSize: layout.compact ? 19 : 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _statusDetail(state),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.gorionTokens.onSurfaceMuted,
                    fontSize: layout.compact ? 13 : 14,
                    height: 1.42,
                  ),
                ),
              ],
            ),
          );

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
                const SizedBox(height: 12),
                Text(
                  _configHint(state),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.gorionTokens.onSurfaceMuted,
                    fontSize: layout.compact ? 13 : 14,
                    height: 1.42,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _profilesDirectoryHint(state),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.gorionTokens.onSurfaceMuted.withValues(
                      alpha: 0.9,
                    ),
                    fontSize: layout.compact ? 12 : 12.5,
                    height: 1.38,
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
              if (bannerText != null) ...[
                SizedBox(height: layout.sectionGap),
                _StatusBanner(
                  text: bannerText,
                  accentColor: bannerColor,
                  compact: layout.ultraCompact,
                ),
              ],
              SizedBox(height: layout.sectionGap),
              if (stacked) ...[
                statusBlock,
                SizedBox(height: layout.sectionGap),
                configBlock,
                SizedBox(height: layout.sectionGap),
                gameFilterBlock,
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          statusBlock,
                          SizedBox(height: layout.sectionGap),
                          gameFilterBlock,
                        ],
                      ),
                    ),
                    SizedBox(width: layout.sectionGap),
                    Expanded(flex: 7, child: configBlock),
                  ],
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
      return 'Boost для zapret сейчас работает только в Windows.';
    }
    if (state.tunConflictActive) {
      return 'TUN-режим sing-box активен, поэтому запуск Boost временно заблокирован.';
    }
    return 'Улучшай связь и загрузку видео без смены сети: выбирай конфиг и управляй Boost в этом разделе.';
  }

  String _statusHeadline(ZapretState state) {
    if (state.errorMessage != null) {
      return 'Запуск требует внимания';
    }
    return switch (state.stage) {
      ZapretStage.running => 'Boost активен',
      ZapretStage.starting => 'Запускаем Boost',
      ZapretStage.stopping => 'Останавливаем Boost',
      ZapretStage.pausedByTun => 'Boost приостановлен',
      ZapretStage.failed => 'Запуск не удался',
      ZapretStage.stopped =>
        state.canStart ? 'Готов к включению' : 'Ожидает действие',
    };
  }

  String _statusDetail(ZapretState state) {
    if (!Platform.isWindows) {
      return 'Отдельный процесс zapret и управление Boost доступны только в Windows.';
    }
    if (state.tunConflictActive) {
      return 'Сейчас включён TUN. Сначала отключи его, затем можно снова запускать Boost.';
    }
    if (state.errorMessage case final errorMessage?) {
      return errorMessage;
    }

    final session = state.runtimeSession;
    return switch (state.stage) {
      ZapretStage.running =>
        session == null
            ? 'Процесс уже работает.'
            : 'PID ${session.processId} • ${_middleEllipsis(session.workingDirectory, 44)}',
      ZapretStage.starting =>
        'Применяем выбранный конфиг и запускаем winws с текущими параметрами.',
      ZapretStage.stopping => 'Останавливаем текущий процесс и очищаем сессию.',
      ZapretStage.failed =>
        'Процесс завершился с ошибкой. Проверь конфиг и статус выше.',
      ZapretStage.pausedByTun =>
        'Boost был остановлен автоматически, потому что активировался TUN-режим.',
      ZapretStage.stopped =>
        state.settings.hasInstallDirectory
            ? 'Папка профилей уже готова. Можно выбрать конфиг и включить Boost.'
            : 'Папка профилей будет создана автоматически при первом открытии.',
    };
  }

  String _configHint(ZapretState state) {
    if (state.availableConfigs.isEmpty) {
      return 'Открой папку профилей, добавь свой .conf и нажми обновить конфиги.';
    }
    if (state.stage == ZapretStage.running) {
      return 'Смену конфига можно сохранить сейчас. Новый конфиг применится после следующего включения.';
    }
    return 'Здесь выбирается активный конфиг. После обновления списка можно сразу переключиться на свой вариант.';
  }

  String _profilesDirectoryHint(ZapretState state) {
    if (!state.settings.hasInstallDirectory) {
      return 'Папка профилей будет создана автоматически при первом открытии.';
    }

    final separator = Platform.pathSeparator;
    final profilesPath =
        '${state.settings.normalizedInstallDirectory}$separator'
        'profiles';
    return 'Папка профилей: ${_middleEllipsis(profilesPath, 72)}';
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
    final count = animation.value * 108.0;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    for (var ix = 0; ix < amountX; ix += 1) {
      for (var iy = 0; iy < amountY; iy += 1) {
        final worldX = ix * separation - (amountX * separation) / 2;
        final worldY =
            math.sin((ix + count) * 0.3) * 50 +
            math.sin((iy + count) * 0.5) * 50;
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
    final size = compact ? 76.0 : 88.0;

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
            borderRadius: BorderRadius.circular(compact ? 24 : 28),
            color: color.withValues(alpha: 0.12),
            border: Border.all(color: color.withValues(alpha: 0.62)),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.14),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: stage == ZapretStage.starting || stage == ZapretStage.stopping
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: compact ? 28 : 32,
                      height: compact ? 28 : 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: color.withValues(alpha: 0.96),
                      ),
                    ),
                    Icon(
                      Icons.close_rounded,
                      size: compact ? 20 : 22,
                      color: color,
                    ),
                  ],
                )
              : SvgPicture.asset(
                  'assets/images/power.svg',
                  width: compact ? 28 : 32,
                  height: compact ? 28 : 32,
                  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                ),
        ),
      ),
    );
  }
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

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.text,
    required this.accentColor,
    this.compact = false,
  });

  final String text;
  final Color accentColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 14,
        vertical: compact ? 7 : 9,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: accentColor.withValues(alpha: 0.10),
        border: Border.all(color: accentColor.withValues(alpha: 0.18)),
      ),
      child: Text(
        text,
        maxLines: compact ? 2 : 3,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface,
          fontSize: compact ? 13 : 14,
          fontWeight: FontWeight.w600,
          height: 1.35,
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

String _middleEllipsis(String value, int maxLength) {
  final trimmed = value.trim();
  if (trimmed.length <= maxLength || maxLength < 9) {
    return trimmed;
  }

  final available = maxLength - 3;
  final prefixLength = available ~/ 2;
  final suffixLength = available - prefixLength;
  return '${trimmed.substring(0, prefixLength)}...${trimmed.substring(trimmed.length - suffixLength)}';
}
