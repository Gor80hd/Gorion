import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:gorion_clean/app/app_router.dart';
import 'package:gorion_clean/core/windows/elevation_relaunch_prompt_service.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';

final appModalRouterProvider = Provider<AppModalRouter>((ref) {
  return GoRouterAppModalRouter(
    navigatorKey: ref.read(rootNavigatorKeyProvider),
  );
});

class AppAlertRouteData {
  const AppAlertRouteData({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;
}

class ServerSettingsRouteData {
  const ServerSettingsRouteData({
    required this.server,
    required this.outbound,
  });

  final OutboundInfo server;
  final Map<String, dynamic>? outbound;
}

abstract class AppModalRouter {
  Future<void> showAddProfile();

  Future<void> showProfilesOverview();

  Future<void> showCustomAlert({
    required String title,
    required String message,
  });

  Future<void> showServerSettings({
    required OutboundInfo server,
    required Map<String, dynamic>? outbound,
  });
}

class GoRouterAppModalRouter implements AppModalRouter {
  const GoRouterAppModalRouter({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Future<void> showAddProfile() {
    return _pushNamed(AppRouteNames.addProfile);
  }

  @override
  Future<void> showProfilesOverview() {
    return _pushNamed(AppRouteNames.profilesOverview);
  }

  @override
  Future<void> showCustomAlert({
    required String title,
    required String message,
  }) {
    return _pushNamed(
      AppRouteNames.alert,
      extra: AppAlertRouteData(title: title, message: message),
    );
  }

  @override
  Future<void> showServerSettings({
    required OutboundInfo server,
    required Map<String, dynamic>? outbound,
  }) {
    return _pushNamed(
      AppRouteNames.serverSettings,
      extra: ServerSettingsRouteData(server: server, outbound: outbound),
    );
  }

  Future<void> _pushNamed(String name, {Object? extra}) async {
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return;
    }
    await context.pushNamed(name, extra: extra);
  }
}
