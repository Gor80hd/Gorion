import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/notifier/auto_server_selection_progress.dart';
import 'package:gorion_clean/features/home/widget/selected_server_preview_provider.dart';
import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/features/proxy/notifier/ip_info_notifier.dart';
import 'package:gorion_clean/utils/server_display_text.dart';

class HomeStatusCardModel {
  const HomeStatusCardModel({
    required this.isAutoMode,
    required this.title,
    this.routeName,
    this.statusText,
    this.alertText,
    this.displayProxy,
    this.currentIp,
    this.sourceIp,
  });

  final bool isAutoMode;
  final String title;
  final String? routeName;
  final String? statusText;
  final String? alertText;
  final OutboundInfo? displayProxy;
  final IpInfo? currentIp;
  final IpInfo? sourceIp;
}

final homeStatusCardProvider = Provider<HomeStatusCardModel>((ref) {
  final state = ref.watch(dashboardControllerProvider);
  final selectedPreview = ref.watch(selectedServerPreviewProvider);
  final pendingManualSelection = ref.watch(pendingServerSelectionProvider);
  final sourceIp = ref.watch(directIpInfoNotifierProvider).valueOrNull;
  final currentIp = ref.watch(ipInfoNotifierProvider).valueOrNull;
  final autoStatus = ref.watch(autoServerSelectionStatusProvider);

  return buildHomeStatusCardModel(
    state: state,
    selectedPreview: selectedPreview,
    pendingManualSelection: pendingManualSelection,
    sourceIp: sourceIp,
    currentIp: currentIp,
    autoStatus: autoStatus,
  );
});

HomeStatusCardModel buildHomeStatusCardModel({
  required DashboardState state,
  required OutboundInfo? selectedPreview,
  required PendingServerSelection? pendingManualSelection,
  required IpInfo? sourceIp,
  required IpInfo? currentIp,
  required String? autoStatus,
}) {
  final autoEnabled = state.autoSelectSettings.enabled;

  final isManualPreviewActive =
      !autoEnabled &&
      (selectedPreview != null || pendingManualSelection != null);
  final isAutoMode = autoEnabled && !isManualPreviewActive;

  final activeProxy = _resolveActiveProxy(state);

  final displayProxy = isAutoMode
      ? activeProxy
      : (selectedPreview ?? activeProxy);
  final routeName = activeProxy == null ? null : _proxyName(activeProxy);

  final rawStatusText = switch ((isAutoMode, autoStatus, routeName)) {
    (true, final String s, _) when s.isNotEmpty => s,
    (true, _, _) => 'Автовыбор активен',
    _ => null,
  };

  final alertText = _normalizeCardText(state.errorMessage);
  final normalizedStatusText = _normalizeCardText(rawStatusText);
  final statusText = alertText != null && normalizedStatusText == alertText
      ? null
      : rawStatusText;

  return HomeStatusCardModel(
    isAutoMode: isAutoMode,
    title: isAutoMode
        ? 'Автоматически'
        : (displayProxy == null ? 'Не выбран' : _proxyName(displayProxy)),
    routeName: routeName,
    statusText: statusText,
    alertText: alertText,
    displayProxy: displayProxy,
    currentIp: currentIp,
    sourceIp: sourceIp,
  );
}

OutboundInfo? _resolveActiveProxy(DashboardState state) {
  final tag = state.activeServerTag ?? state.selectedServerTag;
  if (tag == null) {
    return null;
  }

  for (final profile in state.storage.profiles) {
    for (final server in profile.servers) {
      if (server.tag == tag) {
        return OutboundInfo.fromServerEntry(
          server,
          delay: state.delayByTag[tag] ?? 0,
        );
      }
    }
  }
  return null;
}

String? _normalizeCardText(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

String _proxyName(OutboundInfo info) {
  final raw = info.tagDisplay.isNotEmpty ? info.tagDisplay : info.tag;
  return normalizeServerDisplayText(raw);
}
