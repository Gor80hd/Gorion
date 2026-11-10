import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gap/gap.dart';
import 'package:gorion/app/theme.dart';
import 'package:gorion/core/preferences/general_preferences.dart';
import 'package:gorion/core/widget/emoji_flag_text.dart';
import 'package:gorion/core/widget/glass_panel.dart';
import 'package:gorion/core/widget/page_reveal.dart';
import 'package:gorion/features/auto_select/model/auto_select_state.dart';
import 'package:gorion/features/home/application/dashboard_controller.dart';
import 'package:gorion/features/home/notifier/auto_server_selection_progress.dart';
import 'package:gorion/features/home/notifier/home_status_card_provider.dart';
import 'package:gorion/features/home/utils/globe_country_codes.dart';
import 'package:gorion/features/home/utils/map_location_resolver.dart';
import 'package:gorion/features/home/widget/cobe_style_globe.dart';
import 'package:gorion/features/home/widget/selected_server_preview_provider.dart';
import 'package:gorion/features/intro/utils/region_detector.dart';
import 'package:gorion/features/proxy/model/ip_info_entity.dart';
import 'package:gorion/features/proxy/notifier/ip_info_notifier.dart';
import 'package:gorion/features/proxy/utils/ip_info_display.dart';
import 'package:gorion/features/runtime/model/connection_status.dart';
import 'package:gorion/features/runtime/notifier/connection_notifier.dart';
import 'package:gorion/features/settings/model/singbox_config_enum.dart';
import 'package:gorion/features/stats/notifier/stats_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

part 'map_connection_card.dart';
part 'map_traffic_panel.dart';
part 'map_controls.dart';

(double, double) _resolveLocalFallbackLatLon() {
  final code = _resolveLocalFallbackCountryCode();
  if (code != null) {
    return lookupCountryLatLon(code);
  }
  return defaultMapFallbackLatLon;
}

String? _resolveLocalFallbackCountryCode() {
  final locales = WidgetsBinding.instance.platformDispatcher.locales;
  for (final locale in locales) {
    final code = locale.countryCode;
    if (hasCountryLatLon(code)) {
      return code;
    }
  }

  final detectedCountry = RegionDetector.detect();
  if (hasCountryLatLon(detectedCountry)) {
    return detectedCountry;
  }

  return null;
}

bool _sameIpInfo(IpInfo? left, IpInfo? right) {
  return left?.ip == right?.ip &&
      left?.countryCode == right?.countryCode &&
      left?.region == right?.region &&
      left?.city == right?.city &&
      left?.org == right?.org;
}

class MapView extends HookConsumerWidget {
  const MapView({super.key, required this.contentPadding});

  final EdgeInsets contentPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(connectionNotifierProvider);
    final directIpInfo = ref.watch(directIpInfoNotifierProvider);
    final routedIpInfo = ref.watch(ipInfoNotifierProvider);
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final statusCard = ref.watch(homeStatusCardProvider);
    final statsAsync = ref.watch(statsNotifierProvider);
    final serviceMode = ref.watch(ConfigOptions.serviceMode);
    final isConnected = status.isConnected;
    final isConnecting = status is Connecting;
    final isSwitching = status.isSwitching;
    final keepSourceAnchored = isConnected || isSwitching;
    final shouldUseLocalSource = serviceMode == ServiceMode.systemProxy;
    final sourceAnchor = useState<IpInfo?>(null);
    final mapTransition = useAnimationController(
      duration: const Duration(milliseconds: 1200),
    );
    final packetTravel = useAnimationController(
      duration: const Duration(milliseconds: 3200),
    );

    final sourceInfo = directIpInfo.valueOrNull;
    final routedInfo = routedIpInfo.valueOrNull;
    final activeProxyInfo = activeProxy.valueOrNull;
    final selectedProxy =
        statusCard.displayProxy ??
        (activeProxyInfo?.tag.isNotEmpty == true ? activeProxyInfo : null);
    final destCountry =
        routedInfo?.countryCode ??
        sourceInfo?.countryCode ??
        sourceAnchor.value?.countryCode;

    useEffect(
      () {
        if (sourceInfo != null &&
            !_sameIpInfo(sourceAnchor.value, sourceInfo)) {
          sourceAnchor.value = sourceInfo;
        }
        return null;
      },
      [
        isSwitching,
        sourceInfo?.ip,
        sourceInfo?.countryCode,
        sourceInfo?.region,
        sourceInfo?.city,
        sourceInfo?.org,
      ],
    );

    useEffect(() {
      if (keepSourceAnchored) {
        mapTransition.forward();
        if (!packetTravel.isAnimating) {
          packetTravel.repeat();
        }
      } else {
        mapTransition.reverse();
        packetTravel
          ..stop()
          ..value = 0;
      }
      return null;
    }, [keepSourceAnchored]);

    final mapProgress = useAnimation(mapTransition);
    final packetProgress = useAnimation(packetTravel);

    final uplink = statsAsync.valueOrNull?.uplink ?? 0;
    final downlink = statsAsync.valueOrNull?.downlink ?? 0;

    final srcLatLon = shouldUseLocalSource
        ? _resolveLocalFallbackLatLon()
        : resolveSourceLatLon(sourceInfo ?? sourceAnchor.value);
    final dstLatLon = resolveDestinationLatLon(selectedProxy, destCountry);
    final sourceCountryCode = shouldUseLocalSource
        ? _resolveLocalFallbackCountryCode()
        : sourceInfo?.countryCode ?? sourceAnchor.value?.countryCode;
    final selectedProxyName = selectedProxy == null
        ? ''
        : (selectedProxy.tagDisplay.isNotEmpty
              ? selectedProxy.tagDisplay
              : selectedProxy.tag);
    final destinationCountryCode =
        (selectedProxyName.isNotEmpty
            ? extractMappableCountryCode(selectedProxyName)
            : null) ??
        (keepSourceAnchored ? destCountry : null);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth == 0 || constraints.maxHeight == 0) {
          return const SizedBox.expand();
        }

        final focusProgress = Curves.easeInOutCubicEmphasized.transform(
          mapProgress,
        );
        final revealProgress = Curves.easeOutCubic.transform(
          ((mapProgress - 0.1) / 0.9).clamp(0.0, 1.0),
        );

        return SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CobeStyleGlobe(
                contentPadding: contentPadding,
                sourceLatLon: srcLatLon,
                destinationLatLon: dstLatLon,
                focusProgress: focusProgress,
                revealProgress: revealProgress,
                packetProgress: packetProgress,
                showConnection: keepSourceAnchored,
                isConnected: isConnected,
                sourceColor: const Color(0xFF60A5FA),
                destinationColor: theme.brandAccent,
                sourceCountryIndex: globeCountryIndexFor(sourceCountryCode),
                destinationCountryIndex: globeCountryIndexFor(
                  destinationCountryCode,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: 0,
                child: Padding(
                  padding: contentPadding,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: PageReveal(
                      delay: const Duration(milliseconds: 110),
                      duration: const Duration(milliseconds: 240),
                      offset: const Offset(0, 0.05),
                      child: _ServerInfoPopup(
                        model: statusCard,
                        isConnected: isConnected,
                        isConnecting: isConnecting,
                        isSwitching: isSwitching,
                        downlink: downlink,
                        uplink: uplink,
                        onToggle: () => ref
                            .read(connectionNotifierProvider.notifier)
                            .toggleConnection(),
                        serviceMode: serviceMode,
                        onModeChanged: (mode) => ref
                            .read(ConfigOptions.serviceMode.notifier)
                            .update(mode),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _formatSpeed(int bytesPerSec) {
  if (bytesPerSec <= 0) return '0 KB/s';
  if (bytesPerSec >= 1024 * 1024) {
    final value = bytesPerSec / (1024 * 1024);
    return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} MB/s';
  }
  return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
}

List<ServiceMode> _visibleServiceModes() {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return const [ServiceMode.systemProxy, ServiceMode.tun];
  }
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return const [ServiceMode.mixed, ServiceMode.systemProxy, ServiceMode.tun];
  }
  return const [ServiceMode.mixed, ServiceMode.tun];
}

String _serviceModeLabel(ServiceMode mode) {
  return switch (mode) {
    ServiceMode.mixed => 'Proxy (local)',
    ServiceMode.systemProxy => 'Proxy',
    ServiceMode.tun => 'TUN',
  };
}
