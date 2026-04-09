import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';

class ZapretPage extends ConsumerStatefulWidget {
  const ZapretPage({super.key, this.animateOnMount = true});

  final bool animateOnMount;

  @override
  ConsumerState<ZapretPage> createState() => _ZapretPageState();
}

class _ZapretPageState extends ConsumerState<ZapretPage> {
  late final TextEditingController _installDirectoryController;

  @override
  void initState() {
    super.initState();
    _installDirectoryController = TextEditingController();
  }

  @override
  void dispose() {
    _installDirectoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(zapretControllerProvider);
    final desktopState = ref.watch(desktopSettingsControllerProvider);

    if (_installDirectoryController.text !=
        state.settings.normalizedInstallDirectory) {
      _installDirectoryController.text =
          state.settings.normalizedInstallDirectory;
      _installDirectoryController.selection = TextSelection.collapsed(
        offset: _installDirectoryController.text.length,
      );
    }

    final body = LayoutBuilder(
      builder: (context, constraints) {
        final layout = _ZapretDashboardLayout.fromConstraints(constraints);
        final dashboard = SizedBox(
          key: const ValueKey('zapret-bento-dashboard'),
          width: layout.dashboardWidth,
          height: layout.dashboardHeight,
          child: _buildDashboard(context, state, desktopState, layout),
        );
        return SizedBox.expand(
          child: layout.scaleFallback
              ? FittedBox(
                  fit: BoxFit.contain,
                  alignment: Alignment.topCenter,
                  child: dashboard,
                )
              : dashboard,
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

  Widget _buildDashboard(
    BuildContext context,
    ZapretState state,
    DesktopSettingsState desktopState,
    _ZapretDashboardLayout layout,
  ) {
    if (layout.scaleFallback) {
      final topFlex = layout.ultraCompact ? 4 : 5;
      final bottomFlex = layout.ultraCompact ? 5 : 4;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: topFlex,
                  child: _buildHero(context, state, desktopState, layout),
                ),
                SizedBox(height: layout.gap),
                Expanded(
                  flex: bottomFlex,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _buildInstallCard(context, state, layout),
                      ),
                      SizedBox(width: layout.gap),
                      Expanded(
                        child: _buildProfileCard(context, state, layout),
                      ),
                      SizedBox(width: layout.gap),
                      Expanded(
                        child: _buildStartupCard(
                          context,
                          state,
                          desktopState,
                          layout,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: layout.gap),
          Expanded(flex: 5, child: _buildRuntimeCard(context, state, layout)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: layout.compact ? 11 : 5,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 7,
                child: _buildHero(context, state, desktopState, layout),
              ),
              SizedBox(width: layout.gap),
              Expanded(
                flex: 5,
                child: _buildRuntimeCard(context, state, layout),
              ),
            ],
          ),
        ),
        SizedBox(height: layout.gap),
        Expanded(
          flex: layout.compact ? 7 : 5,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildInstallCard(context, state, layout)),
              SizedBox(width: layout.gap),
              Expanded(child: _buildProfileCard(context, state, layout)),
              SizedBox(width: layout.gap),
              Expanded(
                child: _buildStartupCard(context, state, desktopState, layout),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHero(
    BuildContext context,
    ZapretState state,
    DesktopSettingsState desktopState,
    _ZapretDashboardLayout layout,
  ) {
    final theme = Theme.of(context);
    final stageColor = _stageColor(theme, state.stage);
    final ultraCompact = layout.ultraCompact;
    final subtitle = !Platform.isWindows
        ? 'Управление отдельным процессом zapret2 доступно только в Windows.'
        : state.tunConflictActive
        ? 'Сейчас активен TUN, поэтому запуск zapret2 временно заблокирован.'
        : 'Статус, запуск и автогенерация конфигурации собраны на одном экране.';
    final bannerText = state.errorMessage ?? state.statusMessage;
    final bannerColor = state.errorMessage != null
        ? const Color(0xFFFF8A8A)
        : theme.brandAccent;

    return _buildPanel(
      layout: layout,
      accentColor: stageColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ultraCompact
              ? _CompactPanelHeading(
                  icon: Icons.gpp_good_outlined,
                  title: 'Zapret 2',
                  accentColor: stageColor,
                )
              : _PanelHeading(
                  icon: Icons.gpp_good_outlined,
                  title: 'Zapret 2',
                  description: subtitle,
                  accentColor: stageColor,
                ),
          if (ultraCompact) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.gorionTokens.onSurfaceMuted,
                height: 1.3,
              ),
            ),
          ],
          SizedBox(height: layout.innerGap),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetaPill(label: state.stage.label, color: stageColor),
              if (state.generatedConfigSummary != null)
                _MetaPill(
                  label: state.generatedConfigSummary!,
                  color: _profileAccentColor(theme),
                ),
            ],
          ),
          if (bannerText != null) ...[
            SizedBox(height: layout.innerGap),
            _StatusBanner(
              text: bannerText,
              accentColor: bannerColor,
              compact: ultraCompact,
            ),
          ],
          SizedBox(height: layout.innerGap),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tileWidth = (constraints.maxWidth - layout.innerGap) / 2;
                final heroTiles = ultraCompact
                    ? [
                        (
                          label: 'Профиль',
                          value: _profileSummary(state),
                          color: _profileAccentColor(theme),
                        ),
                        (
                          label: 'TUN',
                          value: state.tunConflictActive
                              ? 'Есть конфликт'
                              : 'Конфликта нет',
                          color: state.tunConflictActive
                              ? const Color(0xFFFFC857)
                              : const Color(0xFF72A8FF),
                        ),
                      ]
                    : [
                        (
                          label: 'Профиль',
                          value: _profileSummary(state),
                          color: _profileAccentColor(theme),
                        ),
                        (
                          label: 'Автостарт',
                          value: state.settings.startOnAppLaunch
                              ? 'Включён'
                              : 'Выключен',
                          color: theme.brandAccent,
                        ),
                        (
                          label: 'Gorion',
                          value: desktopState.launchAtStartupEnabled
                              ? 'С Windows'
                              : 'Ручной запуск',
                          color: const Color(0xFF72A8FF),
                        ),
                        (
                          label: 'TUN',
                          value: state.tunConflictActive
                              ? 'Есть конфликт'
                              : 'Конфликта нет',
                          color: state.tunConflictActive
                              ? const Color(0xFFFFC857)
                              : const Color(0xFF72A8FF),
                        ),
                      ];
                return Align(
                  alignment: Alignment.topLeft,
                  child: Wrap(
                    spacing: layout.innerGap,
                    runSpacing: layout.innerGap,
                    children: [
                      for (final tile in heroTiles)
                        SizedBox(
                          width: tileWidth,
                          child: _MetricTile(
                            label: tile.label,
                            value: tile.value,
                            accentColor: tile.color,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstallCard(
    BuildContext context,
    ZapretState state,
    _ZapretDashboardLayout layout,
  ) {
    final theme = Theme.of(context);
    final compactFallback = layout.scaleFallback;
    final currentPath = state.settings.normalizedInstallDirectory;
    final installNote = currentPath.isEmpty
        ? 'Пустое поле вернёт встроенный runtime-комплект.'
        : 'Текущий путь: ${_middleEllipsis(currentPath, 40)}';

    return _buildPanel(
      layout: layout,
      accentColor: theme.brandAccent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          compactFallback
              ? _CompactPanelHeading(
                  icon: Icons.folder_outlined,
                  title: 'Каталог и генерация',
                  accentColor: theme.brandAccent,
                )
              : _PanelHeading(
                  icon: Icons.folder_outlined,
                  title: 'Каталог и генерация',
                  description:
                      'Можно оставить встроенный комплект или указать свой каталог zapret2.',
                  accentColor: theme.brandAccent,
                ),
          SizedBox(height: compactFallback ? 8 : layout.innerGap),
          Text(
            installNote,
            maxLines: layout.compact
                ? 1
                : compactFallback
                ? 2
                : 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.gorionTokens.onSurfaceMuted,
              fontSize: layout.compact
                  ? 12
                  : compactFallback
                  ? 13
                  : null,
              height: 1.35,
            ),
          ),
          SizedBox(
            height: layout.compact
                ? 8
                : compactFallback
                ? 10
                : 12,
          ),
          TextField(
            controller: _installDirectoryController,
            maxLines: 1,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Каталог zapret2',
              hintText: r'E:\Tools\zapret2',
            ),
            onSubmitted: (_) => _applyInstallDirectory(),
          ),
          SizedBox(
            height: layout.compact
                ? 8
                : compactFallback
                ? 10
                : 12,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: state.busy ? null : _applyInstallDirectory,
                icon: const Icon(Icons.save_outlined),
                label: Text(compactFallback ? 'Путь' : 'Применить'),
                style: compactFallback
                    ? FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )
                    : null,
              ),
              OutlinedButton.icon(
                onPressed: state.busy
                    ? null
                    : () => ref
                          .read(zapretControllerProvider.notifier)
                          .generateConfiguration(),
                icon: const Icon(Icons.auto_fix_high_outlined),
                label: Text(compactFallback ? 'Команда' : 'Предпросмотр'),
                style: compactFallback
                    ? OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )
                    : null,
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildProfileCard(
    BuildContext context,
    ZapretState state,
    _ZapretDashboardLayout layout,
  ) {
    final theme = Theme.of(context);
    final controller = ref.read(zapretControllerProvider.notifier);
    final accentColor = _profileAccentColor(theme);
    final compactFallback = layout.scaleFallback;
    final canAutoTune =
        Platform.isWindows &&
        !state.bootstrapping &&
        !state.busy &&
        !state.tunConflictActive;
    final ultraCompact = layout.ultraCompact;
    final profile = state.settings.effectiveCustomProfile;
    final profileText = layout.scaleFallback
        ? 'Core: ${profile.summaryLabel}'
        : 'Flowseal-style core blocks • ${profile.summaryLabel}';

    return _buildPanel(
      layout: layout,
      accentColor: accentColor,
      padding: EdgeInsets.all(
        layout.compact ? layout.cardPadding - 2 : layout.cardPadding - 1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CompactPanelHeading(
            icon: Icons.auto_awesome_outlined,
            title: 'Flowseal-профиль',
            accentColor: accentColor,
          ),
          SizedBox(height: compactFallback ? 6 : 8),
          if (!ultraCompact && !layout.compact) ...[
            Text(
              profileText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontSize: compactFallback ? 13 : null,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'YouTube, Discord и HTTPS fallback настраиваются независимо; overlays подключаются отдельно.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.gorionTokens.onSurfaceMuted,
                fontSize: compactFallback ? 12.5 : null,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 8),
          ] else if (!ultraCompact) ...[
            Text(
              profileText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.gorionTokens.onSurfaceMuted,
                fontSize: compactFallback ? 12.5 : null,
                height: 1.3,
              ),
            ),
            SizedBox(height: layout.compact ? 6 : 8),
          ] else
            SizedBox(height: layout.compact ? 6 : 10),
          _buildVariantRow(
            theme: theme,
            accentColor: const Color(0xFFFF7A59),
            icon: Icons.ondemand_video_outlined,
            label: 'YouTube',
            value: profile.youtubeVariant,
            dense: layout.compact,
            enabled: !state.busy,
            onSelected: controller.setYoutubeVariant,
          ),
          SizedBox(height: layout.compact ? 6 : 8),
          _buildVariantRow(
            theme: theme,
            accentColor: const Color(0xFF72A8FF),
            icon: Icons.headset_mic_outlined,
            label: 'Discord',
            value: profile.discordVariant,
            dense: layout.compact,
            enabled: !state.busy,
            onSelected: controller.setDiscordVariant,
          ),
          SizedBox(height: layout.compact ? 6 : 8),
          _buildVariantRow(
            theme: theme,
            accentColor: theme.brandAccent,
            icon: Icons.language_outlined,
            label: 'HTTPS',
            value: profile.genericVariant,
            dense: layout.compact,
            enabled: !state.busy,
            onSelected: controller.setGenericVariant,
          ),
          SizedBox(height: layout.compact ? 8 : 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('Game Filter'),
                selected: state.settings.gameFilterEnabled,
                onSelected: state.busy
                    ? null
                    : (value) => controller.setGameFilterEnabled(value),
                avatar: Icon(
                  Icons.sports_esports_outlined,
                  size: 16,
                  color: state.settings.gameFilterEnabled
                      ? accentColor
                      : theme.gorionTokens.onSurfaceMuted,
                ),
                selectedColor: accentColor.withValues(alpha: 0.16),
                checkmarkColor: accentColor,
                side: BorderSide(color: accentColor.withValues(alpha: 0.18)),
              ),
              PopupMenuButton<ZapretIpSetFilterMode>(
                enabled: !state.busy,
                onSelected: controller.setIpSetFilterMode,
                itemBuilder: (context) => [
                  for (final mode in ZapretIpSetFilterMode.values)
                    PopupMenuItem<ZapretIpSetFilterMode>(
                      value: mode,
                      child: Text(mode.label),
                    ),
                ],
                child: _MetaPill(
                  label: ultraCompact
                      ? 'IPSet'
                      : 'IPSet: ${state.settings.ipSetFilterMode.label}',
                  color:
                      state.settings.ipSetFilterMode ==
                          ZapretIpSetFilterMode.none
                      ? theme.gorionTokens.onSurfaceMuted
                      : accentColor,
                ),
              ),
            ],
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: canAutoTune
                ? controller.autoTuneForBlockedResources
                : null,
            icon: state.autotuneRunning
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.onPrimary,
                      ),
                    ),
                  )
                : const Icon(Icons.tune_rounded),
            label: Text(layout.compact ? 'Подбор блоков' : 'Автоподбор блоков'),
          ),
        ],
      ),
    );
  }

  Widget _buildStartupCard(
    BuildContext context,
    ZapretState state,
    DesktopSettingsState desktopState,
    _ZapretDashboardLayout layout,
  ) {
    const accentColor = Color(0xFF72A8FF);

    return _buildPanel(
      layout: layout,
      accentColor: accentColor,
      padding: EdgeInsets.all(
        layout.compact ? layout.cardPadding - 6 : layout.cardPadding - 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          layout.scaleFallback
              ? const _CompactPanelHeading(
                  icon: Icons.desktop_windows_outlined,
                  title: 'Запуск и защита',
                  accentColor: accentColor,
                )
              : const _PanelHeading(
                  icon: Icons.desktop_windows_outlined,
                  title: 'Запуск и защита',
                  description: 'Автостарт Gorion и zapret2 плюс защита от TUN.',
                  accentColor: accentColor,
                ),
          SizedBox(height: layout.compact ? 6 : 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ToggleTile(
                  title: 'Gorion с Windows',
                  value: desktopState.launchAtStartupEnabled,
                  onChanged: desktopState.busy
                      ? null
                      : (value) => ref
                            .read(desktopSettingsControllerProvider.notifier)
                            .setLaunchAtStartupEnabled(value),
                  accentColor: accentColor,
                  dense: layout.ultraCompact,
                ),
                SizedBox(
                  height: layout.ultraCompact
                      ? 2
                      : layout.compact
                      ? 4
                      : 6,
                ),
                _ToggleTile(
                  title: 'Старт zapret2',
                  value: state.settings.startOnAppLaunch,
                  onChanged: state.busy
                      ? null
                      : (value) => ref
                            .read(zapretControllerProvider.notifier)
                            .setStartOnAppLaunch(value),
                  accentColor: const Color(0xFF1EFFAC),
                  dense: layout.ultraCompact,
                ),
                SizedBox(
                  height: layout.ultraCompact
                      ? 2
                      : layout.compact
                      ? 4
                      : 6,
                ),
                _ToggleTile(
                  title: 'Стоп при TUN',
                  value: state.settings.autoStopOnTun,
                  onChanged: null,
                  accentColor: const Color(0xFFFFC857),
                  dense: layout.ultraCompact,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuntimeCard(
    BuildContext context,
    ZapretState state,
    _ZapretDashboardLayout layout,
  ) {
    final theme = Theme.of(context);
    final session = state.runtimeSession;
    final probeReport = state.lastProbeReport;
    final stageColor = _stageColor(theme, state.stage);
    final compactFallback = layout.scaleFallback;
    final ultraCompact = layout.ultraCompact;
    final preview = state.generatedConfigPreview ?? session?.commandPreview;
    final recentLogs = _visibleLogs(state.logs, layout.logLines);
    final runtimeSummary = preview ?? recentLogs.join('\n');

    return _buildPanel(
      layout: layout,
      accentColor: stageColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ultraCompact
                    ? _CompactPanelHeading(
                        icon: Icons.power_settings_new_rounded,
                        title: 'Процесс и лента',
                        accentColor: stageColor,
                      )
                    : _PanelHeading(
                        icon: Icons.power_settings_new_rounded,
                        title: 'Процесс и лента',
                        description: compactFallback
                            ? session == null
                                  ? 'Сессия ещё не запущена.'
                                  : 'PID ${session.processId}'
                            : session == null
                            ? 'Активной сессии пока нет. Кнопки запуска доступны ниже.'
                            : 'PID ${session.processId} • ${_middleEllipsis(session.workingDirectory, 36)}',
                        accentColor: stageColor,
                      ),
              ),
              const SizedBox(width: 10),
              _MetaPill(label: state.stage.label, color: stageColor),
            ],
          ),
          if (ultraCompact) ...[
            const SizedBox(height: 4),
            Text(
              session == null
                  ? 'Сессия ещё не запущена.'
                  : 'PID ${session.processId} • ${_middleEllipsis(session.workingDirectory, 26)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.gorionTokens.onSurfaceMuted,
                height: 1.3,
              ),
            ),
          ],
          SizedBox(height: layout.innerGap),
          if (ultraCompact)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _MetaPill(
                  label: 'PID ${session?.processId ?? 'нет'}',
                  color: stageColor,
                ),
                _MetaPill(
                  label: _runtimeLocationLabel(state, session),
                  color: theme.brandAccent,
                ),
              ],
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final tileWidth = (constraints.maxWidth - layout.innerGap) / 2;
                return Wrap(
                  spacing: layout.innerGap,
                  runSpacing: layout.innerGap,
                  children: [
                    SizedBox(
                      width: tileWidth,
                      child: _MetricTile(
                        label: 'PID',
                        value: session?.processId.toString() ?? 'Нет процесса',
                        accentColor: stageColor,
                      ),
                    ),
                    SizedBox(
                      width: tileWidth,
                      child: _MetricTile(
                        label: 'Каталог',
                        value: _runtimeLocationLabel(state, session),
                        accentColor: theme.brandAccent,
                      ),
                    ),
                  ],
                );
              },
            ),
          SizedBox(height: layout.innerGap),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: state.canStart
                    ? () => ref.read(zapretControllerProvider.notifier).start()
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(compactFallback ? 'Старт' : 'Запустить'),
              ),
              OutlinedButton.icon(
                onPressed: state.canStop
                    ? () => ref.read(zapretControllerProvider.notifier).stop()
                    : null,
                icon: const Icon(Icons.stop_rounded),
                label: Text(compactFallback ? 'Стоп' : 'Остановить'),
              ),
            ],
          ),
          if (probeReport != null) ...[
            SizedBox(height: layout.innerGap),
            Text(
              probeReport.summary,
              maxLines: compactFallback ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.gorionTokens.onSurfaceMuted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final result in probeReport.results)
                  _MetaPill(
                    label:
                        '${result.target.label}${result.latencyMs == null ? '' : ' ${result.latencyMs}ms'}',
                    color: _probeColor(theme, result),
                  ),
              ],
            ),
          ],
          SizedBox(height: layout.innerGap),
          Expanded(
            child: compactFallback
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.32),
                      border: Border.all(
                        color: theme.surfaceStrokeColor(
                          darkAlpha: 0.09,
                          lightAlpha: 0.12,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Сводка',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: SelectableText(
                            runtimeSummary,
                            maxLines: ultraCompact ? 3 : 4,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontFamily: 'IBMPlexSans',
                              fontSize: ultraCompact ? 12.5 : 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _InsetSurface(
                          title: 'Команда',
                          subtitle: preview == null
                              ? 'Сначала сохраните путь или сгенерируйте предпросмотр.'
                              : state.generatedConfigSummary ??
                                    'Предпросмотр запуска winws2.',
                          child: SelectableText(
                            preview ??
                                'Команда появится после генерации предпросмотра или запуска текущего профиля.',
                            maxLines: layout.commandPreviewLines,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontFamily: 'IBMPlexSans',
                              fontSize: 13.5,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: layout.innerGap),
                      Expanded(
                        child: _InsetSurface(
                          title: 'Логи',
                          subtitle: state.logs.isEmpty
                              ? 'Лента ещё пустая.'
                              : 'Показаны последние ${math.min(state.logs.length, layout.logLines)} строк.',
                          child: SelectableText(
                            recentLogs.join('\n'),
                            maxLines: layout.logLines,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.gorionTokens.onSurfaceMuted,
                              fontFamily: 'IBMPlexSans',
                              fontSize: 13,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel({
    required _ZapretDashboardLayout layout,
    required Widget child,
    Color? accentColor,
    EdgeInsetsGeometry? padding,
  }) {
    return GlassPanel(
      borderRadius: layout.panelRadius,
      padding: padding ?? EdgeInsets.all(layout.cardPadding),
      opacity: 0.06,
      backgroundColor: Colors.white,
      strokeColor: accentColor ?? Colors.white,
      strokeOpacity: accentColor == null ? 0.08 : 0.1,
      strokeWidth: 1,
      showGlow: false,
      child: child,
    );
  }

  Future<void> _applyInstallDirectory() async {
    await ref
        .read(zapretControllerProvider.notifier)
        .setInstallDirectory(_installDirectoryController.text);
  }

  List<String> _visibleLogs(List<String> logs, int maxLines) {
    if (logs.isEmpty) {
      return const ['Логи zapret2 пока пусты.'];
    }
    if (logs.length <= maxLines) {
      return logs;
    }

    final visibleCount = math.max(1, maxLines - 1);
    return [
      '... последние $visibleCount строк из ${logs.length}',
      ...logs.skip(logs.length - visibleCount),
    ];
  }

  String _runtimeLocationLabel(
    ZapretState state,
    ZapretRuntimeSession? session,
  ) {
    final path =
        session?.workingDirectory ?? state.settings.normalizedInstallDirectory;
    if (path.isEmpty) {
      return 'Встроенный runtime';
    }
    return _middleEllipsis(_lastPathSegment(path), 20);
  }

  String _profileSummary(ZapretState state) {
    return 'Flowseal • ${state.settings.effectiveCustomProfile.summaryLabel}';
  }

  Color _profileAccentColor(ThemeData theme) {
    return theme.brandAccent;
  }

  Widget _buildVariantRow({
    required ThemeData theme,
    required Color accentColor,
    required IconData icon,
    required String label,
    required ZapretFlowsealVariant value,
    required bool dense,
    required bool enabled,
    required Future<void> Function(ZapretFlowsealVariant variant) onSelected,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 10 : 12,
        vertical: dense ? 8 : 10,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.24,
        ),
        border: Border.all(color: accentColor.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          Icon(icon, size: dense ? 16 : 18, color: accentColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!dense) ...[
                  const SizedBox(height: 2),
                  Text(
                    value.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.gorionTokens.onSurfaceMuted,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          PopupMenuButton<ZapretFlowsealVariant>(
            enabled: enabled,
            onSelected: onSelected,
            itemBuilder: (context) => [
              for (final variant in ZapretFlowsealVariant.values)
                PopupMenuItem<ZapretFlowsealVariant>(
                  value: variant,
                  child: Text(variant.label),
                ),
            ],
            child: _MetaPill(
              label: value.label,
              color: enabled ? accentColor : theme.gorionTokens.onSurfaceMuted,
            ),
          ),
        ],
      ),
    );
  }

  Color _stageColor(ThemeData theme, ZapretStage stage) {
    return switch (stage) {
      ZapretStage.running => const Color(0xFF1EFFAC),
      ZapretStage.starting || ZapretStage.stopping => const Color(0xFFFFC857),
      ZapretStage.failed => const Color(0xFFFF8A8A),
      ZapretStage.pausedByTun => const Color(0xFF72A8FF),
      ZapretStage.stopped => theme.brandAccent,
    };
  }

  Color _probeColor(ThemeData theme, ZapretProbeResult result) {
    if (result.success) {
      return const Color(0xFF1EFFAC);
    }
    if (!result.target.requiredForSuccess) {
      return const Color(0xFFFFC857);
    }
    return const Color(0xFFFF8A8A);
  }
}

class _ZapretDashboardLayout {
  const _ZapretDashboardLayout({
    required this.gap,
    required this.cardPadding,
    required this.innerGap,
    required this.panelRadius,
    required this.commandPreviewLines,
    required this.logLines,
    required this.compact,
    required this.dashboardWidth,
    required this.dashboardHeight,
    required this.scaleFallback,
    required this.ultraCompact,
  });

  factory _ZapretDashboardLayout.fromConstraints(BoxConstraints constraints) {
    final width = math.max(
      1.0,
      constraints.hasBoundedWidth ? constraints.maxWidth : 1340.0,
    );
    final height = math.max(
      1.0,
      constraints.hasBoundedHeight ? constraints.maxHeight : 900.0,
    );
    final compact = width < 980 || height < 620;
    final ultraCompact = width < 720 || height < 460;
    final scaleFallback = width < 1320 || height < 860;
    final fallbackHeight = ultraCompact
        ? 1380.0
        : compact
        ? 1260.0
        : 980.0;
    final fallbackAspectRatio = (width / height).clamp(1.48, 1.72);
    final fallbackWidth = fallbackHeight * fallbackAspectRatio;

    return _ZapretDashboardLayout(
      gap: ultraCompact
          ? 4
          : compact
          ? 6
          : scaleFallback
          ? 12
          : 14,
      cardPadding: ultraCompact
          ? 8
          : compact
          ? 10
          : scaleFallback
          ? 16
          : 18,
      innerGap: ultraCompact
          ? 4
          : compact
          ? 6
          : scaleFallback
          ? 10
          : 12,
      panelRadius: ultraCompact
          ? 16
          : compact
          ? 18
          : scaleFallback
          ? 22
          : 24,
      commandPreviewLines: compact ? 4 : 5,
      logLines: compact ? 5 : 6,
      compact: compact,
      dashboardWidth: scaleFallback ? fallbackWidth : width,
      dashboardHeight: scaleFallback ? fallbackHeight : height,
      scaleFallback: scaleFallback,
      ultraCompact: ultraCompact,
    );
  }

  final double gap;
  final double cardPadding;
  final double innerGap;
  final double panelRadius;
  final int commandPreviewLines;
  final int logLines;
  final bool compact;
  final double dashboardWidth;
  final double dashboardHeight;
  final bool scaleFallback;
  final bool ultraCompact;
}

class _PanelHeading extends StatelessWidget {
  const _PanelHeading({
    required this.icon,
    required this.title,
    required this.description,
    required this.accentColor,
  });

  final IconData icon;
  final String title;
  final String description;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: accentColor.withValues(alpha: 0.14),
          ),
          child: Icon(icon, color: accentColor, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.gorionTokens.onSurfaceMuted,
                  fontSize: 14,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactPanelHeading extends StatelessWidget {
  const _CompactPanelHeading({
    required this.icon,
    required this.title,
    required this.accentColor,
  });

  final IconData icon;
  final String title;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: accentColor.withValues(alpha: 0.14),
          ),
          child: Icon(icon, color: accentColor, size: 18),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.accentColor,
  });

  final String label;
  final String value;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: accentColor.withValues(alpha: 0.08),
        border: Border.all(color: accentColor.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.gorionTokens.onSurfaceMuted,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.title,
    required this.value,
    required this.onChanged,
    required this.accentColor,
    this.dense = false,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color accentColor;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(12, dense ? 6 : 10, 8, dense ? 6 : 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(dense ? 16 : 18),
        color: accentColor.withValues(alpha: 0.08),
        border: Border.all(color: accentColor.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontSize: dense ? 14 : 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(width: dense ? 4 : 6),
          Transform.scale(
            scale: dense ? 0.86 : 1,
            alignment: Alignment.centerRight,
            child: Switch.adaptive(value: value, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

class _InsetSurface extends StatelessWidget {
  const _InsetSurface({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.32,
        ),
        border: Border.all(
          color: theme.surfaceStrokeColor(darkAlpha: 0.09, lightAlpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.gorionTokens.onSurfaceMuted,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Align(alignment: Alignment.topLeft, child: child),
          ),
        ],
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
        color: accentColor.withValues(alpha: 0.1),
        border: Border.all(color: accentColor.withValues(alpha: 0.18)),
      ),
      child: Text(
        text,
        maxLines: compact ? 1 : 2,
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
  const _MetaPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _lastPathSegment(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return 'Встроенный runtime';
  }

  final normalized = trimmed.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? trimmed : parts.last;
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
