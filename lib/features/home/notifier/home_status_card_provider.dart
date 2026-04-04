import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/notifier/auto_server_selection_progress.dart';
import 'package:gorion_clean/features/home/widget/selected_server_preview_provider.dart';
import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/features/proxy/notifier/ip_info_notifier.dart';

class HomeStatusCardModel {
  const HomeStatusCardModel({
    required this.isAutoMode,
    required this.title,
    this.routeName,
    this.statusText,
    this.displayProxy,
    this.currentIp,
    this.sourceIp,
  });

  final bool isAutoMode;
  final String title;
  final String? routeName;
  final String? statusText;
  final OutboundInfo? displayProxy;
  final IpInfo? currentIp;
  final IpInfo? sourceIp;
}

final homeStatusCardProvider = Provider<HomeStatusCardModel>((ref) {
  final state = ref.watch(dashboardControllerProvider);
  final autoEnabled = state.autoSelectSettings.enabled;
  final selectedPreview = ref.watch(selectedServerPreviewProvider);
  final pendingManualSelection = ref.watch(pendingServerSelectionProvider);
  final sourceIp = ref.watch(directIpInfoNotifierProvider).asData?.value;
  final currentIp = ref.watch(ipInfoNotifierProvider).asData?.value;
  final autoStatus = ref.watch(autoServerSelectionStatusProvider);

  final isManualPreviewActive =
      !autoEnabled && (selectedPreview != null || pendingManualSelection != null);
  final isAutoMode = autoEnabled && !isManualPreviewActive;

  OutboundInfo? activeProxy;
  final tag = state.activeServerTag ?? state.selectedServerTag;
  if (tag != null) {
    for (final profile in state.storage.profiles) {
      for (final server in profile.servers) {
        if (server.tag == tag) {
          activeProxy = OutboundInfo.fromServerEntry(
            server,
            delay: state.delayByTag[tag] ?? 0,
          );
          break;
        }
      }
      if (activeProxy != null) break;
    }
  }

  final displayProxy = isAutoMode ? activeProxy : (selectedPreview ?? activeProxy);
  final routeName = activeProxy == null ? null : _proxyName(activeProxy);

  final statusText = switch ((isAutoMode, autoStatus, routeName)) {
    (true, final String s, _) when s.isNotEmpty => s,
    (true, _, _) => 'Автовыбор активен',
    _ => null,
  };

  return HomeStatusCardModel(
    isAutoMode: isAutoMode,
    title: isAutoMode
        ? 'Автоматически'
        : (displayProxy == null ? 'Не выбран' : _proxyName(displayProxy)),
    routeName: routeName,
    statusText: statusText,
    displayProxy: displayProxy,
    currentIp: currentIp,
    sourceIp: sourceIp,
  );
});

String _proxyName(OutboundInfo info) {
  final raw = info.tagDisplay.isNotEmpty ? info.tagDisplay : info.tag;
  return raw.replaceAll(RegExp('§[^§]*'), '').trimRight();
}
