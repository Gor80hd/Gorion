import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/preferences/general_preferences.dart';
import 'package:gorion_clean/core/router/app_modal_router.dart';
import 'package:gorion_clean/core/widget/emoji_flag_text.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_server_exclusion.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/application/server_benchmark_controller.dart';
import 'package:gorion_clean/features/home/application/server_favorites_controller.dart';
import 'package:gorion_clean/features/home/data/server_benchmark_runtime_service.dart';
import 'package:gorion_clean/features/home/model/server_sort_mode.dart';
import 'package:gorion_clean/features/home/notifier/auto_server_selection_progress.dart';
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
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/runtime/notifier/core_restart_signal.dart';
import 'package:gorion_clean/utils/link_parsers.dart';
import 'package:gorion_clean/utils/server_display_text.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

part 'servers_panel_helpers.dart';
part 'servers_panel_controls.dart';
part 'servers_panel_sections.dart';
part 'server_card.dart';
part 'server_settings_dialog.dart';

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
    final favoriteServerKeys = ref.watch(serverFavoritesProvider);
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

    final liveServerPingEnabled = ref.watch(
      dashboardControllerProvider.select(
        (state) => state.autoSelectSettings.liveServerPingEnabled,
      ),
    );
    final liveServerPingInterval = ref.watch(
      dashboardControllerProvider.select(
        (state) => state.autoSelectSettings.liveServerPingInterval,
      ),
    );
    final liveServerPingOnStartupEnabled = ref.watch(
      dashboardControllerProvider.select(
        (state) => state.autoSelectSettings.liveServerPingOnStartupEnabled,
      ),
    );
    final liveServerPingSessionKey = ref.watch(
      dashboardControllerProvider.select((state) {
        final session = state.runtimeSession;
        if (state.connectionStage != ConnectionStage.connected ||
            session == null) {
          return '';
        }
        return '${session.profileId}:${session.controllerPort}';
      }),
    );
    final startupLivePingTriggered = useRef(false);

    useEffect(
      () {
        if (!liveServerPingEnabled || liveServerPingSessionKey.isEmpty) {
          return null;
        }

        var disposed = false;
        Future<void> refreshLivePings() async {
          if (disposed) return;
          final dashboardState = ref.read(dashboardControllerProvider);
          if (!dashboardState.autoSelectSettings.liveServerPingEnabled ||
              dashboardState.connectionStage != ConnectionStage.connected ||
              dashboardState.runtimeSession == null ||
              dashboardState.refreshingDelays ||
              dashboardState.busy ||
              ref.read(serverBenchmarkControllerProvider).active) {
            return;
          }
          await ref
              .read(dashboardControllerProvider.notifier)
              .refreshDelays(silent: true);
        }

        Timer? initialTimer;
        if (liveServerPingOnStartupEnabled && !startupLivePingTriggered.value) {
          startupLivePingTriggered.value = true;
          initialTimer = Timer(
            const Duration(milliseconds: 750),
            () => unawaited(refreshLivePings()),
          );
        }
        final timer = Timer.periodic(
          liveServerPingInterval,
          (_) => unawaited(refreshLivePings()),
        );
        return () {
          disposed = true;
          initialTimer?.cancel();
          timer.cancel();
        };
      },
      [
        liveServerPingEnabled,
        liveServerPingInterval,
        liveServerPingOnStartupEnabled,
        liveServerPingSessionKey,
      ],
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
    final liveDelayByTag = ref.watch(
      dashboardControllerProvider.select((state) => state.delayByTag),
    );
    final dashboardBusy = ref.watch(
      dashboardControllerProvider.select((state) => state.busy),
    );
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
      useMemoized(proxyRepo.watchProxies, [proxyRepo, coreRestartSignal]),
    );

    final onlineGroup = groupAsync.data?.fold((_) => null, (g) => g);
    final currentOnlineServer = onlineGroup == null
        ? null
        : _visibleServers(onlineGroup).cast<OutboundInfo?>().firstWhere(
            (server) => server?.tag == onlineGroup.selected,
            orElse: () => null,
          );
    final autoCardPing = autoServerSelectionProgress == null
        ? (currentOnlineServer == null
              ? null
              : liveDelayByTag[currentOnlineServer.tag] ??
                    currentOnlineServer.urlTestDelay)
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
        liveDelayByTag[server.tag] ??
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

    bool isFavoriteServer(String profileId, OutboundInfo server) {
      return favoriteServerKeys.contains(_benchmarkKey(profileId, server.tag));
    }

    Future<void> toggleFavoriteServer(
      ProfileEntity profile,
      OutboundInfo server,
    ) async {
      await ref
          .read(serverFavoritesProvider.notifier)
          .toggle(_benchmarkKey(profile.id, server.tag));
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
      await result.match<Future<void>?>(
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
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              borderRadius: 24,
              backgroundColor: _softAccentSurface(theme, emphasis: 0.76),
              opacity: 0.07,
              strokeOpacity: 0.10,
              strokeColor: theme.brandAccent,
              boxShadow: [
                BoxShadow(
                  color: theme.shadowColor.withValues(alpha: 0.18),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _GlassTextField(
                          controller: searchCtrl,
                          hint: 'Поиск',
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 20,
                            color: _softAccentForeground(theme, emphasis: 0.60),
                          ),
                        ),
                      ),
                      const Gap(8),
                      _SubscriptionMenuButton(
                        showUpdate: isRemoteProfile,
                        updateRunning: updateState?.running == true,
                        onAdd: () =>
                            ref.read(appModalRouterProvider).showAddProfile(),
                        onManage: () => ref
                            .read(appModalRouterProvider)
                            .showProfilesOverview(),
                        onUpdate: updateState?.running == true
                            ? null
                            : () {
                                unawaited(
                                  ref
                                      .read(
                                        foregroundProfilesUpdateNotifierProvider
                                            .notifier,
                                      )
                                      .trigger(),
                                );
                              },
                      ),
                    ],
                  ),
                  const Gap(10),
                  Row(
                    children: [
                      Expanded(
                        child: _SortDropdown(
                          value: sortMode,
                          onChanged: (mode) {
                            unawaited(
                              ref
                                  .read(Preferences.serverSortMode.notifier)
                                  .update(mode),
                            );
                          },
                        ),
                      ),
                      const Gap(8),
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
            Expanded(
              child: _ServerListWindow(
                child: () {
                  if (profilesAsync.connectionState ==
                          ConnectionState.waiting &&
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
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
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
                    padding: const EdgeInsets.only(bottom: 4),
                    children: [
                      const _ServerSectionLabel('РЕКОМЕНДОВАННЫЕ'),
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
                                    disabledForegroundColor:
                                        autoResetDisabledInk,
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
                              const Gap(6),
                              _ServerPingChip(
                                ping: autoCardPing ?? 0,
                                color: _pingColor(autoCardPing ?? 0),
                                selected: autoCardSelected,
                              ),
                            ],
                          ),
                          selectionProgress: autoServerSelectionProgress,
                          onSelect: () async {
                            ref
                                    .read(
                                      selectedServerPreviewProvider.notifier,
                                    )
                                    .state =
                                null;
                            ref
                                    .read(
                                      pendingServerSelectionProvider.notifier,
                                    )
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
                      const Gap(10),
                      const _ServerSectionLabel('ВСЕ СЕРВЕРЫ'),
                      const Gap(8),
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
                                                  ((pendingSelection
                                                                  ?.profileId ==
                                                              profile.id &&
                                                          pendingSelection
                                                                  ?.outboundTag ==
                                                              server.tag) ||
                                                      (isActiveProfile &&
                                                          (selectedPreview !=
                                                                  null
                                                              ? selectedPreview
                                                                        .tag ==
                                                                    server.tag
                                                              : server
                                                                    .isSelected))),
                                              groupName: '',
                                              groupTag: sectionGroup.tag,
                                              pingOverride: effectivePing(
                                                profile.id,
                                                server,
                                              ),
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
                                              isFavorite: isFavoriteServer(
                                                profile.id,
                                                server,
                                              ),
                                              onToggleFavorite: () => unawaited(
                                                toggleFavoriteServer(
                                                  profile,
                                                  server,
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
                                                      if (liveGroupTag ==
                                                          null) {
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
                                                        final currentPending =
                                                            ref.read(
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
            ),
          ],
        ),
      ),
    );
  }
}
