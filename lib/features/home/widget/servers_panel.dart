import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/preferences/general_preferences.dart';
import 'package:gorion_clean/core/router/app_modal_router.dart';
import 'package:gorion_clean/core/widget/emoji_flag_text.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/application/server_benchmark_controller.dart';
import 'package:gorion_clean/features/home/data/server_benchmark_runtime_service.dart';
import 'package:gorion_clean/features/home/model/server_sort_mode.dart';
import 'package:gorion_clean/features/home/notifier/auto_server_selection_progress.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_server_exclusion.dart';
import 'package:gorion_clean/features/home/widget/selected_server_preview_provider.dart';
import 'package:gorion_clean/features/profiles/data/profile_data_providers.dart';
import 'package:gorion_clean/features/profiles/model/profile_connection_mode.dart';
import 'package:gorion_clean/features/profiles/model/profile_entity.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart'
    show autoSelectServerTag;
import 'package:gorion_clean/features/profiles/model/profile_sort_enum.dart';
import 'package:gorion_clean/features/profiles/notifier/active_profile_notifier.dart';
import 'package:gorion_clean/features/profiles/notifier/profiles_update_notifier.dart';
import 'package:gorion_clean/features/profiles/utils/profile_display_order.dart';
import 'package:gorion_clean/features/proxy/data/proxy_data_providers.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/features/runtime/notifier/core_restart_signal.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/utils/link_parsers.dart';
import 'package:gorion_clean/utils/server_display_text.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

part 'servers_panel_helpers.dart';

class ServersPanelWidget extends HookConsumerWidget {
  const ServersPanelWidget({super.key});

  static const panelWidth = 348.0;
  static const topOffset = 50.0;
  static const searchFieldHeight = 48.0;
  static const searchFieldRadius = 20.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final searchCtrl = useTextEditingController();
    final searchQuery = useState('');
    final sortMode = ref.watch(Preferences.serverSortMode);
    final expandedSubscriptionIds = useState<Set<String>>({});
    final selectedPreview = ref.watch(selectedServerPreviewProvider);
    final pendingSelection = ref.watch(pendingServerSelectionProvider);
    final benchmarkState = ref.watch(serverBenchmarkControllerProvider);
    final activeProfile = ref.watch(activeProfileProvider).asData?.value;
    final profileRepo = ref.watch(profileRepoFacadeProvider).valueOrNull;
    final profileDataSource = ref.watch(profileDataSourceProvider);
    final storedProfileOrder = ref.watch(Preferences.profileDisplayOrder);
    final connectionMode = ref.watch(Preferences.profileConnectionMode);
    final profilesStream = useMemoized(
      () => profileDataSource
          .watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.ascending)
          .map((entries) => entries.map((entry) => entry.toEntity()).toList()),
      [profileDataSource],
    );
    final profilesAsync = useStream(profilesStream);

    useEffect(() {
      var disposed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (disposed || !context.mounted) return;
        if (pendingSelection != null) return;
        ref.read(selectedServerPreviewProvider.notifier).state = null;
      });
      return () => disposed = true;
    }, [activeProfile?.id]);

    final allProfiles = sortProfilesForDisplay(
      profilesAsync.data ?? const <ProfileEntity>[],
      storedProfileOrder,
    );

    useEffect(() {
      void listener() => searchQuery.value = searchCtrl.text;
      searchCtrl.addListener(listener);
      return () => searchCtrl.removeListener(listener);
    }, [searchCtrl]);
    ref.listen<bool>(
      serverBenchmarkControllerProvider.select((state) => state.active),
      (previous, next) {
        if (previous == true && !next) {
          ref.read(selectedServerPreviewProvider.notifier).state = null;
        }
      },
    );

    final proxyRepo = ref.watch(proxyRepositoryProvider);
    final coreRestartSignal = ref.watch(coreRestartSignalProvider);
    final autoServerSelectionEnabled = ref.watch(Preferences.autoSelectServer);
    final autoServerSelected = ref.watch(
      dashboardControllerProvider.select(
        (state) => state.selectedServerTag == autoSelectServerTag,
      ),
    );
    final autoReconnectCacheAvailable = ref.watch(
      dashboardControllerProvider.select(
        (state) => state.hasRecentSuccessfulAutoConnectForActiveProfile,
      ),
    );
    final dashboardBusy = ref.watch(
      dashboardControllerProvider.select((state) => state.busy),
    );
    final connectionTuningSettings = ref.watch(
      dashboardControllerProvider.select(
        (state) => state.connectionTuningSettings,
      ),
    );
    final zapretState = ref.watch(zapretControllerProvider);
    final autoSelectBestServerCheckIntervalMinutes = ref.watch(
      dashboardControllerProvider.select(
        (state) => state.autoSelectSettings.bestServerCheckIntervalMinutes,
      ),
    );
    final autoServerSelectionExcluded = ref.watch(
      dashboardControllerProvider.select(
        (state) => state.autoSelectSettings.excludedServerKeys.toSet(),
      ),
    );
    final autoServerSelectionStatus = ref.watch(
      autoServerSelectionStatusProvider,
    );
    final autoServerSelectionProgress = ref.watch(
      autoServerSelectionProgressProvider,
    );
    final groupAsync = useStream(
      useMemoized(() => proxyRepo.watchProxies(), [
        proxyRepo,
        coreRestartSignal,
      ]),
    );

    final onlineGroup = groupAsync.data?.fold((_) => null, (g) => g);
    final currentOnlineServer = onlineGroup == null
        ? null
        : _visibleServers(onlineGroup).cast<OutboundInfo?>().firstWhere(
            (server) => server?.tag == onlineGroup.selected,
            orElse: () => null,
          );
    final autoCardPing = autoServerSelectionProgress == null
        ? currentOnlineServer?.urlTestDelay
        : 0;
    final autoCardServer = OutboundInfo(
      tag: 'Автоматически',
      tagDisplay: 'Автоматически',
      type: 'auto',
      isVisible: true,
      isGroup: false,
      urlTestDelay: autoCardPing ?? 0,
    );
    final autoCardDescription = autoServerSelectionEnabled
        ? (autoServerSelectionStatus ?? 'Автовыбор включён')
        : 'Выберет лучший доступный сервер, кроме исключённых';
    const autoCardDetailLines = <String>[];
    final autoCardSelected =
        autoServerSelected &&
        selectedPreview == null &&
        pendingSelection == null;
    final autoResetEnabled = autoReconnectCacheAvailable && !dashboardBusy;
    const autoResetTagColor = Color(0xFFFFB86B);
    const autoIntervalTagColor = Color(0xFF6DD3FF);
    final autoTagInk = theme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.96)
        : Colors.black.withValues(alpha: 0.88);
    final autoTagDisabledInk = theme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.48)
        : Colors.black.withValues(alpha: 0.42);
    final autoResetTooltipMessage = autoReconnectCacheAvailable
        ? dashboardBusy
              ? 'Быстрый кеш переподключения сохранён. Сброс будет доступен после завершения текущего действия.'
              : 'Сбросить быстрый кеш переподключения'
        : 'Быстрый кеш переподключения уже пуст';
    final autoResetDisabledInk = autoReconnectCacheAvailable
        ? autoTagInk.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.72 : 0.62,
          )
        : autoTagDisabledInk;
    final autoResetBackgroundColor = autoResetTagColor.withValues(
      alpha: autoReconnectCacheAvailable
          ? (autoResetEnabled ? 0.14 : 0.1)
          : 0.07,
    );
    final autoResetBorderColor = autoResetTagColor.withValues(
      alpha: autoReconnectCacheAvailable
          ? (autoResetEnabled ? 0.35 : 0.24)
          : 0.18,
    );
    final activeProfileLabel = activeProfile?.name ?? 'Нет активной подписки';
    final updateState = ref
        .watch(foregroundProfilesUpdateNotifierProvider)
        .valueOrNull;
    final visibleProfiles = allProfiles
        .where((profile) => profile.userOverride?.showOnHome ?? true)
        .toList();
    final visibleProfilesKey = visibleProfiles
        .map(
          (profile) =>
              '${profile.id}:${profile.lastUpdate.millisecondsSinceEpoch}',
        )
        .join('|');
    final subscriptionsSubtitle = allProfiles.isEmpty
        ? 'Добавьте первую подписку из буфера обмена, ссылки или QR-кода'
        : connectionMode == ProfileConnectionMode.mergedProfiles
        ? '${visibleProfiles.length} из ${allProfiles.length} отображаются · Режим: общий пул'
        : '${visibleProfiles.length} из ${allProfiles.length} отображаются · Текущая: $activeProfileLabel';
    final parsedSubscriptionGroupsAsync = useFuture(
      useMemoized(() async {
        if (profileRepo == null) return <String, OutboundGroup?>{};

        final groups = <String, OutboundGroup?>{};
        for (final profile in visibleProfiles) {
          final rawConfig = await profileRepo
              .getRawConfig(profile.id)
              .getOrElse((_) => '')
              .run();
          if (rawConfig.isEmpty) {
            groups[profile.id] = null;
            continue;
          }
          final parsed = _parseOfflineGroup(
            rawConfig,
            fallbackGroupName: profile.name,
          );
          groups[profile.id] = parsed == null ? null : _toOutboundGroup(parsed);
        }
        return groups;
      }, [profileRepo, visibleProfilesKey, coreRestartSignal]),
    );

    useEffect(() {
      final visibleIds = visibleProfiles.map((profile) => profile.id).toSet();
      final retained = expandedSubscriptionIds.value
          .where(visibleIds.contains)
          .toSet();
      final missing = visibleIds.difference(retained);
      expandedSubscriptionIds.value = {...retained, ...missing};
      return null;
    }, [visibleProfilesKey]);

    final parsedSubscriptionGroups =
        parsedSubscriptionGroupsAsync.data ?? const <String, OutboundGroup?>{};
    OutboundGroup? subscriptionGroup(ProfileEntity profile) {
      if (profile.id == activeProfile?.id && onlineGroup != null) {
        return onlineGroup;
      }
      return parsedSubscriptionGroups[profile.id];
    }

    int effectivePing(String profileId, OutboundInfo server) =>
        benchmarkState.pingResults[_benchmarkKey(profileId, server.tag)] ??
        server.urlTestDelay;

    int effectiveSpeed(String profileId, OutboundInfo server) =>
        benchmarkState.speedResults[_benchmarkKey(profileId, server.tag)] ?? 0;

    String autoSelectExclusionKey(String profileId, OutboundInfo server) {
      return buildAutoSelectServerExclusionKey(
        profileId: profileId,
        serverTag: server.tag,
      );
    }

    bool isAutoSelectExcluded(String profileId, OutboundInfo server) {
      return autoServerSelectionExcluded.contains(
        autoSelectExclusionKey(profileId, server),
      );
    }

    Future<void> toggleAutoSelectExclusion(
      ProfileEntity profile,
      OutboundInfo server,
    ) async {
      await ref
          .read(dashboardControllerProvider.notifier)
          .setAutoSelectServerExcluded(
            server.tag,
            !isAutoSelectExcluded(profile.id, server),
            profileId: profile.id,
          );
    }

    List<OutboundInfo> visibleSubscriptionServers(ProfileEntity profile) {
      final sectionGroup = subscriptionGroup(profile);
      if (sectionGroup == null) return const <OutboundInfo>[];

      var sectionServers = _visibleServers(sectionGroup);

      if (searchQuery.value.isNotEmpty) {
        final q = searchQuery.value.toLowerCase();
        sectionServers = sectionServers
            .where((s) => _displayName(s).toLowerCase().contains(q))
            .toList();
      }

      final originalOrder = <String, int>{
        for (var index = 0; index < sectionServers.length; index += 1)
          sectionServers[index].tag: index,
      };
      int compareOriginalOrder(OutboundInfo a, OutboundInfo b) =>
          (originalOrder[a.tag] ?? 0).compareTo(originalOrder[b.tag] ?? 0);

      switch (sortMode) {
        case ServerSortMode.ping:
          sectionServers = [...sectionServers]
            ..sort((a, b) {
              final da = effectivePing(profile.id, a);
              final db = effectivePing(profile.id, b);
              if (da == 0 && db == 0) {
                return compareOriginalOrder(a, b);
              }
              if (da == 0) return 1;
              if (db == 0) return -1;
              final compare = da.compareTo(db);
              if (compare != 0) return compare;
              return compareOriginalOrder(a, b);
            });
        case ServerSortMode.speed:
          sectionServers = [...sectionServers]
            ..sort((a, b) {
              final sa = effectiveSpeed(profile.id, a);
              final sb = effectiveSpeed(profile.id, b);
              final aHasSpeed = sa > 0;
              final bHasSpeed = sb > 0;

              if (aHasSpeed && bHasSpeed) {
                final compare = sb.compareTo(sa);
                if (compare != 0) return compare;
              } else if (aHasSpeed != bHasSpeed) {
                return aHasSpeed ? -1 : 1;
              }

              return compareOriginalOrder(a, b);
            });
        case ServerSortMode.alpha:
          sectionServers = [...sectionServers]
            ..sort((a, b) {
              final compare = _displayName(
                a,
              ).toLowerCase().compareTo(_displayName(b).toLowerCase());
              if (compare != 0) return compare;
              return compareOriginalOrder(a, b);
            });
        case ServerSortMode.none:
          break;
      }

      return sectionServers;
    }

    Duration serverCardRevealDelay(int index, {int baseMilliseconds = 0}) {
      final staggerIndex = index > 8 ? 8 : index;
      return Duration(milliseconds: baseMilliseconds + (staggerIndex * 36));
    }

    final isRemoteProfile = activeProfile is RemoteProfileEntity;

    Future<void> showServerSettings(
      ProfileEntity profile,
      OutboundInfo server,
    ) async {
      Map<String, dynamic>? outbound;
      if (profileRepo != null) {
        final generatedConfig = await profileRepo
            .generateConfig(profile.id)
            .getOrElse((_) => '')
            .run();
        if (generatedConfig.isNotEmpty) {
          outbound = extractOutboundDefinition(generatedConfig, server.tag);
        }
      }

      await ref
          .read(appModalRouterProvider)
          .showServerSettings(server: server, outbound: outbound);
    }

    Future<void> setActiveSubscription(ProfileEntity profile) async {
      final repo = await ref.read(profileRepoFacadeProvider.future);
      final result = await repo.setAsActive(profile.id).run();
      result.match(
        (err) => ref
            .read(appModalRouterProvider)
            .showCustomAlert(
              title: 'Не удалось сделать подписку текущей',
              message: err.toString(),
            ),
        (_) => null,
      );
    }

    Future<void> runBatchBenchmark() async {
      if (benchmarkState.active || activeProfile == null) {
        return;
      }
      try {
        await ref
            .read(serverBenchmarkControllerProvider.notifier)
            .runActiveProfileBatch(activeProfile: activeProfile);
      } catch (error) {
        await ref
            .read(appModalRouterProvider)
            .showCustomAlert(
              title: 'Не удалось запустить пакетный тест',
              message: error.toString(),
            );
      }
    }

    return SizedBox(
      width: panelWidth,
      child: Padding(
        padding: const EdgeInsets.only(top: topOffset, bottom: 16, left: 8),
        child: Column(
          children: [
            GlassPanel(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              borderRadius: 20,
              backgroundColor: _softAccentSurface(theme, emphasis: 0.82),
              opacity: 0.08,
              strokeOpacity: 0.14,
              strokeColor: theme.brandAccent,
              boxShadow: [
                BoxShadow(
                  color: theme.shadowColor.withValues(alpha: 0.18),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
              child: Column(
                children: [
                  _GlassTextField(
                    controller: searchCtrl,
                    hint: 'Поиск',
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: _softAccentForeground(theme, emphasis: 0.60),
                    ),
                  ),
                  const Gap(8),
                  Row(
                    children: [
                      Expanded(
                        child: _SortDropdown(
                          value: sortMode,
                          onChanged: (mode) {
                            ref
                                .read(Preferences.serverSortMode.notifier)
                                .update(mode);
                          },
                        ),
                      ),
                      const Gap(6),
                      if (benchmarkState.active)
                        _SmallGlassButton(
                          icon: Icons.stop_circle_rounded,
                          tooltip: 'Остановить тест',
                          isStop: true,
                          onTap: () {
                            ref
                                .read(
                                  serverBenchmarkControllerProvider.notifier,
                                )
                                .stop();
                          },
                        )
                      else
                        _SmallGlassButton(
                          icon: Icons.network_check_rounded,
                          tooltip: 'Параллельный тест серверов',
                          onTap: activeProfile != null
                              ? runBatchBenchmark
                              : null,
                        ),
                      if (isRemoteProfile) ...[
                        const Gap(6),
                        _SmallGlassButton(
                          icon: updateState?.running == true
                              ? Icons.sync_rounded
                              : Icons.refresh_rounded,
                          tooltip: 'Обновить подписки',
                          onTap: updateState?.running == true
                              ? null
                              : () {
                                  ref
                                      .read(
                                        foregroundProfilesUpdateNotifierProvider
                                            .notifier,
                                      )
                                      .trigger();
                                },
                        ),
                      ],
                    ],
                  ),
                  if (benchmarkState.active ||
                      benchmarkState.status != null) ...[
                    const Gap(10),
                    _PingTestProgress(
                      completed: benchmarkState.completed,
                      total: benchmarkState.total,
                      status: benchmarkState.status,
                      elapsed: benchmarkState.elapsed,
                    ),
                  ],
                ],
              ),
            ),
            const Gap(8),
            _HomeGameFilterPanel(
              enabled:
                  zapretState.settings.gameFilterEnabled &&
                  connectionTuningSettings.bypassSteamForSystemProxy,
              busy: zapretState.busy || dashboardBusy,
              onChanged: (value) async {
                await ref
                    .read(zapretControllerProvider.notifier)
                    .setGameFilterEnabled(value);
                await ref
                    .read(dashboardControllerProvider.notifier)
                    .saveConnectionTuningSettings(
                      connectionTuningSettings.copyWith(
                        bypassSteamForSystemProxy: value,
                      ),
                    );
              },
            ),
            const Gap(8),
            _SubscriptionStrip(
              title: 'Подписки',
              subtitle: subscriptionsSubtitle,
              updateState: updateState,
              onAdd: () => ref.read(appModalRouterProvider).showAddProfile(),
              onManage: () =>
                  ref.read(appModalRouterProvider).showProfilesOverview(),
            ),
            Expanded(
              child: () {
                if (profilesAsync.connectionState == ConnectionState.waiting &&
                    !profilesAsync.hasData) {
                  return Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary,
                    ),
                  );
                }
                if (allProfiles.isEmpty) {
                  return const Center(child: _EmptyServersCard());
                }
                if (allProfiles.isNotEmpty && visibleProfiles.isEmpty) {
                  return ListView(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    children: [
                      _SubscriptionsHiddenHint(
                        onManage: () => ref
                            .read(appModalRouterProvider)
                            .showProfilesOverview(),
                      ),
                    ],
                  );
                }

                return ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    const Gap(8),
                    PageReveal(
                      key: const ValueKey('auto-server-card-reveal'),
                      delay: serverCardRevealDelay(0, baseMilliseconds: 40),
                      duration: const Duration(milliseconds: 220),
                      child: _ServerCard(
                        key: const ValueKey('auto-server-card'),
                        server: autoCardServer,
                        isSelected: autoCardSelected,
                        groupName: autoCardDescription,
                        detailLines: autoCardDetailLines,
                        groupTag: onlineGroup?.tag ?? '',
                        pingOverride: autoCardPing,
                        hasSpeedResult: false,
                        isBenchmarking: false,
                        badge: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Tooltip(
                              message: autoResetTooltipMessage,
                              child: TextButton(
                                onPressed: autoResetEnabled
                                    ? () async {
                                        await ref
                                            .read(
                                              dashboardControllerProvider
                                                  .notifier,
                                            )
                                            .resetRecentSuccessfulAutoConnect();
                                      }
                                    : null,
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(0, 0),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  foregroundColor: autoTagInk,
                                  disabledForegroundColor: autoResetDisabledInk,
                                  backgroundColor: autoResetBackgroundColor,
                                  disabledBackgroundColor:
                                      autoResetBackgroundColor,
                                  side: BorderSide(
                                    color: autoResetBorderColor,
                                    width: 0.7,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                                child: const Text('RESET'),
                              ),
                            ),
                            const Gap(6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: autoIntervalTagColor.withValues(
                                  alpha: 0.14,
                                ),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: autoIntervalTagColor.withValues(
                                    alpha: 0.35,
                                  ),
                                  width: 0.7,
                                ),
                              ),
                              child: Text(
                                _formatBestServerCheckIntervalBadge(
                                  autoSelectBestServerCheckIntervalMinutes,
                                ),
                                style: TextStyle(
                                  color: autoTagInk,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                        selectionProgress: autoServerSelectionProgress,
                        onSelect: () async {
                          ref
                                  .read(selectedServerPreviewProvider.notifier)
                                  .state =
                              null;
                          ref
                                  .read(pendingServerSelectionProvider.notifier)
                                  .state =
                              null;
                          await ref
                              .read(Preferences.autoSelectServer.notifier)
                              .update(true);
                          await ref
                              .read(dashboardControllerProvider.notifier)
                              .selectServer(autoSelectServerTag);
                        },
                      ),
                    ),
                    const Gap(2),
                    for (final profile in visibleProfiles) ...[
                      Builder(
                        builder: (context) {
                          final sectionGroup = subscriptionGroup(profile);
                          final sectionServers = visibleSubscriptionServers(
                            profile,
                          );
                          final isExpanded = expandedSubscriptionIds.value
                              .contains(profile.id);
                          final isActiveProfile =
                              connectionMode ==
                                  ProfileConnectionMode.currentProfile &&
                              profile.id == activeProfile?.id;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _SubscriptionCompactRow(
                                name: profile.name,
                                serverCount: sectionServers.length,
                                isActive: isActiveProfile,
                                isExpanded: isExpanded,
                                onTap: () {
                                  final next = {
                                    ...expandedSubscriptionIds.value,
                                  };
                                  if (!next.add(profile.id)) {
                                    next.remove(profile.id);
                                  }
                                  expandedSubscriptionIds.value = next;
                                },
                              ),
                              if (isExpanded) ...[
                                const Gap(6),
                                if (sectionGroup == null)
                                  const _SubscriptionServersPlaceholder(
                                    message:
                                        'Не удалось загрузить серверы для этой подписки.',
                                  )
                                else if (sectionServers.isEmpty)
                                  _SubscriptionServersPlaceholder(
                                    message: searchQuery.value.isNotEmpty
                                        ? 'По текущему фильтру серверы не найдены.'
                                        : 'В этой подписке пока нет доступных серверов.',
                                  )
                                else
                                  for (
                                    var index = 0;
                                    index < sectionServers.length;
                                    index++
                                  ) ...[
                                    Builder(
                                      builder: (context) {
                                        final server = sectionServers[index];
                                        final isAutoExcluded =
                                            isAutoSelectExcluded(
                                              profile.id,
                                              server,
                                            );
                                        return PageReveal(
                                          key: ValueKey(
                                            'reveal-${_benchmarkKey(profile.id, server.tag)}',
                                          ),
                                          delay: serverCardRevealDelay(
                                            index,
                                            baseMilliseconds: 90,
                                          ),
                                          duration: const Duration(
                                            milliseconds: 220,
                                          ),
                                          offset: const Offset(0, 0.045),
                                          child: _ServerCard(
                                            key: ValueKey(
                                              _benchmarkKey(
                                                profile.id,
                                                server.tag,
                                              ),
                                            ),
                                            server: server,
                                            isSelected:
                                                !autoCardSelected &&
                                                ((pendingSelection?.profileId ==
                                                            profile.id &&
                                                        pendingSelection
                                                                ?.outboundTag ==
                                                            server.tag) ||
                                                    (isActiveProfile &&
                                                        (selectedPreview != null
                                                            ? selectedPreview
                                                                      .tag ==
                                                                  server.tag
                                                            : server
                                                                  .isSelected))),
                                            groupName: '',
                                            groupTag: sectionGroup.tag,
                                            pingOverride:
                                                benchmarkState
                                                    .pingResults[_benchmarkKey(
                                                  profile.id,
                                                  server.tag,
                                                )],
                                            speedOverride:
                                                benchmarkState
                                                    .speedResults[_benchmarkKey(
                                                  profile.id,
                                                  server.tag,
                                                )],
                                            hasSpeedResult: benchmarkState
                                                .speedResults
                                                .containsKey(
                                                  _benchmarkKey(
                                                    profile.id,
                                                    server.tag,
                                                  ),
                                                ),
                                            isBenchmarking: benchmarkState
                                                .benchmarkingKeys
                                                .contains(
                                                  _benchmarkKey(
                                                    profile.id,
                                                    server.tag,
                                                  ),
                                                ),
                                            isAutoExcluded: isAutoExcluded,
                                            onToggleAutoExclusion: () =>
                                                toggleAutoSelectExclusion(
                                                  profile,
                                                  server,
                                                ),
                                            onShowDetails: () =>
                                                showServerSettings(
                                                  profile,
                                                  server,
                                                ),
                                            onSelect: benchmarkState.active
                                                ? null
                                                : () async {
                                                    await ref
                                                        .read(
                                                          Preferences
                                                              .autoSelectServer
                                                              .notifier,
                                                        )
                                                        .update(false);
                                                    final selectionRequestId =
                                                        DateTime.now()
                                                            .microsecondsSinceEpoch;
                                                    ref
                                                        .read(
                                                          selectedServerPreviewProvider
                                                              .notifier,
                                                        )
                                                        .state = server.clone()
                                                      ..isSelected = true;
                                                    ref
                                                        .read(
                                                          pendingServerSelectionProvider
                                                              .notifier,
                                                        )
                                                        .state = PendingServerSelection(
                                                      requestId:
                                                          selectionRequestId,
                                                      profileId: profile.id,
                                                      groupTag:
                                                          connectionMode ==
                                                              ProfileConnectionMode
                                                                  .mergedProfiles
                                                          ? null
                                                          : sectionGroup.tag,
                                                      outboundTag: server.tag,
                                                    );
                                                    if (!isActiveProfile &&
                                                        connectionMode ==
                                                            ProfileConnectionMode
                                                                .currentProfile) {
                                                      await setActiveSubscription(
                                                        profile,
                                                      );
                                                      return;
                                                    }
                                                    final liveGroupTag =
                                                        connectionMode ==
                                                            ProfileConnectionMode
                                                                .mergedProfiles
                                                        ? onlineGroup?.tag
                                                        : sectionGroup.tag;
                                                    if (liveGroupTag == null) {
                                                      return;
                                                    }
                                                    final result = await ref
                                                        .read(
                                                          proxyRepositoryProvider,
                                                        )
                                                        .selectProxy(
                                                          liveGroupTag,
                                                          server.tag,
                                                        )
                                                        .run();
                                                    result.match((_) => null, (
                                                      _,
                                                    ) {
                                                      final currentPending = ref
                                                          .read(
                                                            pendingServerSelectionProvider,
                                                          );
                                                      if (currentPending
                                                              ?.requestId ==
                                                          selectionRequestId) {
                                                        ref
                                                                .read(
                                                                  pendingServerSelectionProvider
                                                                      .notifier,
                                                                )
                                                                .state =
                                                            null;
                                                      }
                                                    });
                                                  },
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                              ],
                              const Gap(8),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                );
              }(),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassTextField extends StatelessWidget {
  const _GlassTextField({
    required this.controller,
    required this.hint,
    this.prefixIcon,
  });

  final TextEditingController controller;
  final String hint;
  final Widget? prefixIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassPanel(
      height: ServersPanelWidget.searchFieldHeight,
      borderRadius: ServersPanelWidget.searchFieldRadius,
      backgroundColor: _softAccentSurface(theme, emphasis: 0.70),
      opacity: 0.05,
      strokeOpacity: 0.04,
      strokeColor: theme.brandAccent,
      child: TextField(
        controller: controller,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(
          color: scheme.onSurface,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: Theme.of(context).gorionTokens.onSurfaceMuted,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
          prefixIcon: prefixIcon,
          prefixIconConstraints: prefixIcon == null
              ? null
              : const BoxConstraints(
                  minWidth: 42,
                  minHeight: ServersPanelWidget.searchFieldHeight,
                ),
          contentPadding: prefixIcon == null
              ? const EdgeInsets.symmetric(horizontal: 18)
              : const EdgeInsets.only(right: 18),
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
        ),
      ),
    );
  }
}

class _SortDropdown extends StatelessWidget {
  const _SortDropdown({required this.value, required this.onChanged});

  final ServerSortMode value;
  final ValueChanged<ServerSortMode> onChanged;

  String get _label => switch (value) {
    ServerSortMode.none => 'Без сортировки',
    ServerSortMode.ping => 'По пингу',
    ServerSortMode.speed => 'По скорости',
    ServerSortMode.alpha => 'По алфавиту',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final isActive = value != ServerSortMode.none;
    final accentColor = _softAccentForeground(
      theme,
      emphasis: theme.brightness == Brightness.dark ? 1.0 : 0.92,
    );

    return GlassPanel(
      height: 42,
      borderRadius: 15,
      backgroundColor: _softAccentSurface(
        theme,
        emphasis: isActive ? 0.95 : 0.74,
      ),
      opacity: isActive ? 0.08 : 0.05,
      strokeOpacity: isActive ? 0.12 : 0.04,
      strokeColor: theme.brandAccent,
      child: PopupMenuButton<ServerSortMode>(
        initialValue: value,
        tooltip: 'Сортировка',
        onSelected: onChanged,
        color: scheme.surface,
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        itemBuilder: (context) => [
          _sortMenuItem(context, ServerSortMode.none, 'Без сортировки', value),
          _sortMenuItem(context, ServerSortMode.ping, 'По пингу', value),
          _sortMenuItem(context, ServerSortMode.speed, 'По скорости', value),
          _sortMenuItem(context, ServerSortMode.alpha, 'По алфавиту', value),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 15,
                color: isActive ? accentColor : muted.withValues(alpha: 0.9),
              ),
              const Gap(8),
              Expanded(
                child: Text(
                  _label,
                  style: TextStyle(
                    color: isActive
                        ? accentColor
                        : scheme.onSurface.withValues(alpha: 0.72),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: muted.withValues(alpha: 0.85),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<ServerSortMode> _sortMenuItem(
    BuildContext context,
    ServerSortMode mode,
    String label,
    ServerSortMode currentValue,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = mode == currentValue;

    return PopupMenuItem<ServerSortMode>(
      value: mode,
      child: Row(
        children: [
          Icon(
            selected ? Icons.check_rounded : Icons.circle_outlined,
            size: 16,
            color: selected
                ? scheme.primary
                : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.9),
          ),
          const Gap(8),
          Text(
            label,
            style: TextStyle(
              color: selected
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.82),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallGlassButton extends StatelessWidget {
  const _SmallGlassButton({
    required this.icon,
    this.tooltip = '',
    this.isStop = false,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool isStop;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    final iconColor = isStop
        ? scheme.error.withValues(alpha: 0.88)
        : enabled
        ? _softAccentForeground(theme, emphasis: 0.92)
        : theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.45);

    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: GlassPanel(
          width: 42,
          height: 42,
          borderRadius: 15,
          backgroundColor: isStop
              ? scheme.error
              : _softAccentSurface(theme, emphasis: enabled ? 0.92 : 0.55),
          opacity: isStop ? 0.1 : (enabled ? 0.06 : 0.03),
          strokeOpacity: isStop ? 0.14 : (enabled ? 0.08 : 0.03),
          strokeColor: isStop ? scheme.error : theme.brandAccent,
          child: Center(child: Icon(icon, size: 17, color: iconColor)),
        ),
      ),
    );
  }
}

class _PingTestProgress extends StatelessWidget {
  const _PingTestProgress({
    required this.completed,
    required this.total,
    required this.status,
    required this.elapsed,
  });

  final int completed;
  final int total;
  final String? status;
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final progress = total > 0 ? completed / total : null;
    final label =
        status ??
        (total > 0
            ? 'Проверено $completed из $total'
            : 'Подготовка benchmark…');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.72),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Gap(8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _softAccentFill(theme, emphasis: 0.95),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: _softAccentBorder(theme, emphasis: 0.95),
                  width: 0.7,
                ),
              ),
              child: Text(
                _formatElapsed(elapsed),
                style: TextStyle(
                  color: muted.withValues(alpha: 1),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
        const Gap(6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            minHeight: 6,
            value: total > 0 ? progress : null,
            backgroundColor: _softAccentFill(theme, emphasis: 0.9),
            valueColor: AlwaysStoppedAnimation(scheme.primary),
          ),
        ),
      ],
    );
  }
}

class _SubscriptionStrip extends StatelessWidget {
  const _SubscriptionStrip({
    required this.title,
    required this.subtitle,
    required this.updateState,
    this.onAdd,
    this.onManage,
  });

  final String title;
  final String subtitle;
  final ({
    String? currentName,
    int completed,
    int total,
    int updated,
    int failed,
    bool running,
    bool force,
    DateTime? lastRun,
    String? message,
  })?
  updateState;
  final VoidCallback? onAdd;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final isRunning = updateState?.running == true;
    final progress = isRunning && (updateState?.total ?? 0) > 0
        ? (updateState!.completed / updateState!.total).clamp(0.0, 1.0)
        : null;
    final statusLine = isRunning
        ? '${updateState?.message ?? 'Обновляем подписки…'}${updateState?.currentName != null ? ' · ${updateState!.currentName}' : ''}'
        : _formatUpdateSummary(updateState);

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      borderRadius: 15,
      backgroundColor: _softAccentSurface(theme, emphasis: 0.86),
      opacity: 0.06,
      strokeOpacity: 0.08,
      strokeColor: theme.brandAccent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Gap(2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: muted.withValues(alpha: 0.95),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Gap(8),
              _SmallGlassButton(
                icon: Icons.add_rounded,
                tooltip: 'Добавить подписку',
                onTap: onAdd,
              ),
              const Gap(6),
              _SmallGlassButton(
                icon: Icons.inventory_2_outlined,
                tooltip: 'Список подписок',
                onTap: onManage,
              ),
            ],
          ),
          if (statusLine != null && statusLine.isNotEmpty) ...[
            const Gap(10),
            Text(
              statusLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.7),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (isRunning) ...[
            const Gap(8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: progress,
                backgroundColor: _softAccentFill(theme, emphasis: 0.9),
                valueColor: AlwaysStoppedAnimation(scheme.primary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubscriptionCompactRow extends StatelessWidget {
  const _SubscriptionCompactRow({
    required this.name,
    required this.serverCount,
    required this.isActive,
    required this.isExpanded,
    required this.onTap,
  });

  final String name;
  final int serverCount;
  final bool isActive;
  final bool isExpanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final accent = isActive
        ? _softAccentForeground(theme, emphasis: 0.96)
        : scheme.onSurface.withValues(alpha: 0.72);
    final badgeFill = isActive
        ? _softAccentFill(theme, emphasis: 1.30)
        : _softAccentFill(theme, emphasis: 0.78);
    final badgeBorder = isActive
        ? _softAccentBorder(theme, emphasis: 1.20)
        : _softAccentBorder(theme, emphasis: 0.82);
    final strokeColor = isActive
        ? Color.lerp(
            theme.brandAccent,
            scheme.onSurface,
            theme.brightness == Brightness.dark ? 0.26 : 0.12,
          )!
        : theme.brandAccent;
    final countColor = isActive
        ? _softAccentForeground(theme, emphasis: 0.96)
        : muted.withValues(alpha: 0.84);

    return GestureDetector(
      onTap: onTap,
      child: GlassPanel(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        borderRadius: 14,
        backgroundColor: _softAccentSurface(
          theme,
          emphasis: isActive ? 0.96 : 0.78,
        ),
        opacity: isActive ? 0.06 : 0.04,
        strokeOpacity: isActive ? 0.10 : 0.04,
        strokeColor: strokeColor,
        gradientBegin: const Alignment(-1, -0.95),
        gradientEnd: const Alignment(0.82, 1),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: badgeFill,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: badgeBorder, width: 0.8),
              ),
              child: Icon(Icons.layers_rounded, size: 12.5, color: accent),
            ),
            const Gap(10),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w800 : FontWeight.w700,
                  height: 1,
                  letterSpacing: 0.15,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '$serverCount',
              style: TextStyle(
                color: countColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
            const Gap(8),
            AnimatedRotation(
              turns: isExpanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: isActive
                    ? scheme.primary.withValues(alpha: 0.82)
                    : muted.withValues(alpha: 0.72),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionServersPlaceholder extends StatelessWidget {
  const _SubscriptionServersPlaceholder({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).gorionTokens.onSurfaceMuted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 0, 2),
      child: Text(
        message,
        style: TextStyle(
          color: muted.withValues(alpha: 0.95),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _SubscriptionActionChip extends StatelessWidget {
  const _SubscriptionActionChip({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _softAccentForeground(theme, emphasis: 0.86);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _softAccentFill(theme, emphasis: 1.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _softAccentBorder(theme, emphasis: 1.05),
            width: 0.7,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const Gap(6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionsHiddenHint extends StatelessWidget {
  const _SubscriptionsHiddenHint({required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      borderRadius: 15,
      backgroundColor: _softAccentSurface(theme, emphasis: 0.74),
      opacity: 0.05,
      strokeOpacity: 0.07,
      strokeColor: theme.brandAccent,
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Все подписки скрыты. Включите нужные в настройках подписок.',
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.68),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Gap(10),
          _SubscriptionActionChip(
            icon: Icons.tune_rounded,
            label: 'Открыть',
            onTap: onManage,
          ),
        ],
      ),
    );
  }
}

String? _formatUpdateSummary(
  ({
    String? currentName,
    int completed,
    int total,
    int updated,
    int failed,
    bool running,
    bool force,
    DateTime? lastRun,
    String? message,
  })?
  updateState,
) {
  if (updateState == null) {
    return 'Автообновление проверяет подписки каждые 15 минут.';
  }
  if (updateState.message?.isNotEmpty == true && updateState.running == false) {
    return '${updateState.message}${updateState.lastRun != null ? ' · ${_formatLastRun(updateState.lastRun!)}' : ''}';
  }
  if (updateState.lastRun != null) {
    return _formatLastRun(updateState.lastRun!);
  }
  return 'Автообновление проверяет подписки каждые 15 минут.';
}

String _formatLastRun(DateTime lastRun) {
  final local = lastRun.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'Последняя проверка: ${two(local.day)}.${two(local.month)} ${two(local.hour)}:${two(local.minute)}';
}

class _EmptyServersCard extends StatelessWidget {
  const _EmptyServersCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return GlassPanel(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: 15,
      backgroundColor: Colors.white,
      opacity: 0.05,
      strokeOpacity: 0.09,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(
            FontAwesomeIcons.satellite,
            size: 16,
            color: theme.gorionTokens.onSurfaceMuted.withValues(alpha: 0.48),
          ),
          const Gap(8),
          Text(
            'Нет серверов',
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: 0.72),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

enum _ServerCardMenuAction { toggleAutoExclusion, details }

class _ServerCard extends HookConsumerWidget {
  const _ServerCard({
    super.key,
    required this.server,
    required this.isSelected,
    required this.groupName,
    this.detailLines = const [],
    required this.groupTag,
    this.pingOverride,
    this.speedOverride,
    required this.hasSpeedResult,
    required this.isBenchmarking,
    this.badge,
    this.selectionProgress,
    this.isAutoExcluded = false,
    this.onToggleAutoExclusion,
    this.onShowDetails,
    this.onSelect,
  });

  final OutboundInfo server;
  final bool isSelected;
  final String groupName;
  final List<String> detailLines;
  final String groupTag;
  final int? pingOverride;
  final int? speedOverride;
  final bool hasSpeedResult;
  final bool isBenchmarking;
  final Widget? badge;
  final AutoServerSelectionProgress? selectionProgress;
  final bool isAutoExcluded;
  final VoidCallback? onToggleAutoExclusion;
  final VoidCallback? onShowDetails;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final isLightTheme = theme.brightness == Brightness.light;

    final pulseCtrl = useAnimationController(
      duration: const Duration(milliseconds: 900),
    );
    final pulseValue = useAnimation(pulseCtrl);
    useEffect(() {
      if (isBenchmarking) {
        pulseCtrl.repeat(reverse: true);
      } else {
        pulseCtrl
          ..stop()
          ..value = 0;
      }
      return null;
    }, [isBenchmarking]);

    final name = _displayName(server);
    final cc = _extractCountryCode(name);
    final flag = cc != null ? _flagEmoji(cc) : '';
    final displayedName = cc != null ? _stripCountryPrefix(name) : name;
    final type = server.type.isNotEmpty ? server.type.toUpperCase() : 'PROXY';
    final ping = pingOverride ?? server.urlTestDelay;
    final showAccent = isSelected;
    final selectedPrimaryInk = (isLightTheme ? Colors.black : Colors.white)
        .withValues(alpha: isLightTheme ? 0.88 : 0.96);
    final selectedSecondaryInk = (isLightTheme ? Colors.black : Colors.white)
        .withValues(alpha: isLightTheme ? 0.72 : 0.84);
    final selectedTertiaryInk = (isLightTheme ? Colors.black : Colors.white)
        .withValues(alpha: isLightTheme ? 0.62 : 0.76);
    final selectedMetricInk = (isLightTheme ? Colors.black : Colors.white)
        .withValues(alpha: isLightTheme ? 0.82 : 0.92);
    final typeColor = _typeColor(server.type, theme.brandAccent);
    final pingColor = _pingColor(ping);
    final throughput = speedOverride;
    final speedColor = switch (throughput ?? -1) {
      < 1 => const Color(0xFFEF4444),
      < 256 * 1024 => const Color(0xFFF59E0B),
      < 1024 * 1024 => const Color(0xFF22C55E),
      _ => theme.brandAccent,
    };
    final darkNeutralCardSurface = Color.lerp(
      const Color(0xFF050706),
      scheme.onSurface,
      0.05,
    )!;
    final baseCardBackgroundColor = isLightTheme
        ? isBenchmarking
              ? scheme.onSurface.withValues(alpha: 0.050)
              : isSelected
              ? scheme.onSurface.withValues(alpha: 0.036)
              : scheme.onSurface.withValues(alpha: 0.022)
        : darkNeutralCardSurface.withValues(
            alpha: isBenchmarking ? 0.92 : (isSelected ? 0.88 : 0.80),
          );
    final cardBackgroundColor = showAccent && !isBenchmarking
        ? Color.lerp(
            baseCardBackgroundColor,
            theme.brandAccent,
            isLightTheme ? 0.10 : 0.18,
          )!
        : baseCardBackgroundColor;
    final baseCardBorderColor = isLightTheme
        ? isBenchmarking
              ? scheme.onSurface.withValues(alpha: 0.22)
              : scheme.onSurface.withValues(alpha: isSelected ? 0.16 : 0.12)
        : scheme.onSurface.withValues(
            alpha: isBenchmarking ? 0.18 : (isSelected ? 0.16 : 0.10),
          );
    final cardBorderColor = showAccent && !isBenchmarking
        ? Color.lerp(
            baseCardBorderColor,
            theme.brandAccent,
            isLightTheme ? 0.50 : 0.72,
          )!
        : baseCardBorderColor;
    final cardShadowColor = showAccent
        ? theme.brandAccent.withValues(alpha: isLightTheme ? 0.12 : 0.18)
        : isLightTheme
        ? scheme.onSurface.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.22);
    final actionsButtonFillColor = showAccent
        ? theme.brandAccent.withValues(alpha: isLightTheme ? 0.14 : 0.22)
        : scheme.onSurface.withValues(alpha: isLightTheme ? 0.05 : 0.08);
    final actionsButtonBorderColor = showAccent
        ? theme.brandAccent.withValues(alpha: isLightTheme ? 0.28 : 0.42)
        : scheme.onSurface.withValues(alpha: isLightTheme ? 0.12 : 0.14);
    final actionsButtonIconColor = showAccent
        ? selectedPrimaryInk
        : scheme.onSurface.withValues(alpha: 0.88);
    final typeTagFillColor = showAccent
        ? theme.brandAccent.withValues(alpha: isLightTheme ? 0.92 : 0.96)
        : typeColor.withValues(alpha: 0.13);
    final typeTagBorderColor = showAccent
        ? theme.brandAccent
        : typeColor.withValues(alpha: 0.35);
    final typeTagTextColor = showAccent
        ? selectedPrimaryInk
        : scheme.onSurface.withValues(alpha: 0.88);
    final hasActionsMenu =
        onShowDetails != null || onToggleAutoExclusion != null;

    return GestureDetector(
      onTap: onSelect,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: isBenchmarking
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(
                      alpha: 0.06 + pulseValue * 0.22,
                    ),
                    blurRadius: 12 + pulseValue * 14,
                    spreadRadius: -2,
                  ),
                ],
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: cardBackgroundColor,
                border: Border.all(
                  color: cardBorderColor,
                  width: isBenchmarking ? 1.3 : 0.7,
                ),
                boxShadow: (isSelected && !isBenchmarking)
                    ? [
                        BoxShadow(
                          color: cardShadowColor,
                          blurRadius: 18,
                          spreadRadius: -2,
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                children: [
                  if (isSelected)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(width: 3.5, color: theme.brandAccent),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (flag.isNotEmpty) ...[
                                    Text(
                                      flag,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontFamily: 'Emoji',
                                      ),
                                    ),
                                    const Gap(6),
                                  ],
                                  Expanded(
                                    child: Text(
                                      displayedName,
                                      style: TextStyle(
                                        color: isSelected
                                            ? selectedPrimaryInk
                                            : scheme.onSurface.withValues(
                                                alpha: 0.9,
                                              ),
                                        fontSize: 14,
                                        fontWeight: isSelected
                                            ? FontWeight.w700
                                            : FontWeight.w600,
                                        letterSpacing: 0.1,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              if (groupName.isNotEmpty) ...[
                                const Gap(2),
                                Text(
                                  groupName,
                                  style: TextStyle(
                                    color: isSelected
                                        ? selectedSecondaryInk
                                        : muted.withValues(alpha: 0.78),
                                    fontSize: 12,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.fade,
                                ),
                              ],
                              if (detailLines.isNotEmpty) ...[
                                const Gap(6),
                                for (
                                  var index = 0;
                                  index < detailLines.length;
                                  index += 1
                                ) ...[
                                  Text(
                                    detailLines[index],
                                    style: TextStyle(
                                      color: isSelected
                                          ? selectedTertiaryInk
                                          : muted.withValues(alpha: 0.95),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      height: 1.25,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (index != detailLines.length - 1)
                                    const Gap(2),
                                ],
                              ],
                              if (isAutoExcluded) ...[
                                const Gap(6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFFEF4444,
                                    ).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: const Color(
                                        0xFFEF4444,
                                      ).withValues(alpha: 0.26),
                                      width: 0.7,
                                    ),
                                  ),
                                  child: Text(
                                    'Исключён из автовыбора',
                                    style: TextStyle(
                                      color: const Color(
                                        0xFFFF8A8A,
                                      ).withValues(alpha: 0.96),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.25,
                                    ),
                                  ),
                                ),
                              ],
                              if (selectionProgress != null) ...[
                                const Gap(6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: SizedBox(
                                    height: 4,
                                    child: LinearProgressIndicator(
                                      value: selectionProgress!.value,
                                      backgroundColor: _softAccentFill(
                                        theme,
                                        emphasis: 0.92,
                                      ),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        theme.brandAccent,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const Gap(8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isBenchmarking)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scheme.primary.withValues(
                                        alpha: 0.14,
                                      ),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: scheme.primary.withValues(
                                          alpha: 0.38,
                                        ),
                                        width: 0.7,
                                      ),
                                    ),
                                    child: Text(
                                      'TEST',
                                      style: TextStyle(
                                        color: scheme.onSurface.withValues(
                                          alpha: 0.88,
                                        ),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  )
                                else if (badge != null)
                                  badge!
                                else
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: typeTagFillColor,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: typeTagBorderColor,
                                        width: 0.7,
                                      ),
                                    ),
                                    child: Text(
                                      type,
                                      style: TextStyle(
                                        color: typeTagTextColor,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ),
                                if (hasActionsMenu) ...[
                                  const Gap(6),
                                  PopupMenuButton<_ServerCardMenuAction>(
                                    tooltip: 'Действия',
                                    color: scheme.surface,
                                    elevation: 12,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    onSelected: (action) {
                                      switch (action) {
                                        case _ServerCardMenuAction
                                            .toggleAutoExclusion:
                                          onToggleAutoExclusion?.call();
                                        case _ServerCardMenuAction.details:
                                          onShowDetails?.call();
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      if (onToggleAutoExclusion != null)
                                        PopupMenuItem<_ServerCardMenuAction>(
                                          value: _ServerCardMenuAction
                                              .toggleAutoExclusion,
                                          child: Row(
                                            children: [
                                              Icon(
                                                isAutoExcluded
                                                    ? Icons
                                                          .playlist_add_check_circle_rounded
                                                    : Icons.block_rounded,
                                                size: 18,
                                                color: isAutoExcluded
                                                    ? scheme.primary
                                                    : const Color(0xFFEF4444),
                                              ),
                                              const Gap(10),
                                              Text(
                                                isAutoExcluded
                                                    ? 'Вернуть в автовыбор'
                                                    : 'Исключить из автовыбора',
                                                style: TextStyle(
                                                  color: scheme.onSurface
                                                      .withValues(alpha: 0.92),
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      if (onShowDetails != null)
                                        PopupMenuItem<_ServerCardMenuAction>(
                                          value: _ServerCardMenuAction.details,
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.tune_rounded,
                                                size: 18,
                                                color: muted.withValues(
                                                  alpha: 0.95,
                                                ),
                                              ),
                                              const Gap(10),
                                              Text(
                                                'Параметры сервера',
                                                style: TextStyle(
                                                  color: scheme.onSurface
                                                      .withValues(alpha: 0.92),
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: actionsButtonFillColor,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: isAutoExcluded
                                              ? const Color(
                                                  0xFFEF4444,
                                                ).withValues(alpha: 0.22)
                                              : actionsButtonBorderColor,
                                          width: 0.7,
                                        ),
                                      ),
                                      child: Icon(
                                        isAutoExcluded
                                            ? Icons.block_rounded
                                            : Icons.more_horiz_rounded,
                                        size: 15,
                                        color: isAutoExcluded
                                            ? const Color(
                                                0xFFFF8A8A,
                                              ).withValues(alpha: 0.96)
                                            : actionsButtonIconColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (ping == -1) ...[
                              const Gap(5),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 5,
                                    height: 5,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFFEF4444),
                                    ),
                                  ),
                                  const Gap(4),
                                  Text(
                                    'NO',
                                    style: TextStyle(
                                      color: isSelected
                                          ? selectedMetricInk
                                          : const Color(0xFFEF4444),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ] else if (ping > 0) ...[
                              const Gap(5),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 5,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: pingColor,
                                    ),
                                  ),
                                  const Gap(4),
                                  Text(
                                    '$ping ms',
                                    style: TextStyle(
                                      color: isSelected
                                          ? selectedMetricInk
                                          : pingColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (isBenchmarking && !hasSpeedResult) ...[
                              const Gap(4),
                              Text(
                                'benchmark…',
                                style: TextStyle(
                                  color: scheme.onSurface.withValues(
                                    alpha: 0.82,
                                  ),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                            if (hasSpeedResult) ...[
                              const Gap(4),
                              Text(
                                throughput != null && throughput > 0
                                    ? _formatRate(throughput)
                                    : 'FAIL',
                                style: TextStyle(
                                  color: isSelected
                                      ? selectedPrimaryInk
                                      : throughput != null && throughput > 0
                                      ? speedColor
                                      : const Color(0xFFEF4444),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              Text(
                                isBenchmarking
                                    ? 'live throughput'
                                    : 'throughput',
                                style: TextStyle(
                                  color: isSelected
                                      ? selectedSecondaryInk
                                      : muted.withValues(alpha: 0.82),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeGameFilterPanel extends StatelessWidget {
  const _HomeGameFilterPanel({
    required this.enabled,
    required this.busy,
    required this.onChanged,
  });

  final bool enabled;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    const accent = Color(0xFF72A8FF);

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      borderRadius: 18,
      backgroundColor: _softAccentSurface(theme, emphasis: 0.72),
      opacity: 0.07,
      strokeOpacity: 0.12,
      strokeColor: accent,
      showGlow: false,
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: enabled ? 0.16 : 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: accent.withValues(alpha: enabled ? 0.28 : 0.12),
                width: 0.8,
              ),
            ),
            child: Icon(
              Icons.sports_esports_rounded,
              size: 18,
              color: enabled
                  ? accent.withValues(alpha: 0.96)
                  : muted.withValues(alpha: 0.72),
            ),
          ),
          const Gap(10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GameFilter',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  'Игры и Steam',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: muted.withValues(alpha: 0.86),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const Gap(8),
          Switch.adaptive(value: enabled, onChanged: busy ? null : onChanged),
        ],
      ),
    );
  }
}

class ServerSettingsDialog extends StatelessWidget {
  const ServerSettingsDialog({
    super.key,
    required this.server,
    required this.outbound,
  });

  final OutboundInfo server;
  final Map<String, dynamic>? outbound;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final prettyJson = outbound == null
        ? null
        : const JsonEncoder.withIndent('  ').convert(outbound);

    Widget infoRow(String title, String value) {
      if (value.isEmpty || value == '0') return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(
                title,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.88),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Gap(8),
            Expanded(
              child: SelectableText(
                value,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.74),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: GlassPanel(
        borderRadius: 24,
        backgroundColor: scheme.surface,
        opacity: 0.9,
        strokeOpacity: 0.14,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                EmojiFlagText(
                  _displayName(server),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Gap(16),
                infoRow('Тип', server.type.toUpperCase()),
                infoRow('Host', server.host),
                infoRow('Port', server.port.toString()),
                infoRow('Tag', server.tag),
                if (prettyJson != null) ...[
                  Divider(
                    height: 24,
                    color: scheme.onSurface.withValues(alpha: 0.08),
                  ),
                  Text(
                    'Сырые настройки сервера',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Gap(8),
                  GlassPanel(
                    borderRadius: 16,
                    backgroundColor: Colors.white,
                    opacity: 0.04,
                    strokeOpacity: 0.04,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      prettyJson,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.78),
                      ),
                    ),
                  ),
                ] else
                  Text(
                    'Полная конфигурация сейчас недоступна, но базовые параметры сервера уже видны.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: muted.withValues(alpha: 0.95),
                    ),
                  ),
                const Gap(16),
                Row(
                  children: [
                    if (prettyJson != null)
                      Expanded(
                        child: _DialogActionButton(
                          label: 'Копировать JSON',
                          accent: true,
                          onTap: () => Clipboard.setData(
                            ClipboardData(text: prettyJson),
                          ),
                        ),
                      ),
                    if (prettyJson != null) const Gap(10),
                    Expanded(
                      child: _DialogActionButton(
                        label: 'Закрыть',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({
    required this.label,
    this.onTap,
    this.accent = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = accent ? scheme.primary : scheme.onSurface;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: accent
              ? scheme.primary.withValues(alpha: 0.14)
              : scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.22), width: 0.8),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}
