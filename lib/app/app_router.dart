import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:gorion_clean/app/shell.dart';
import 'package:gorion_clean/core/router/app_modal_router.dart';
import 'package:gorion_clean/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:gorion_clean/core/router/dialog/dialog_notifier.dart';
import 'package:gorion_clean/core/windows/elevation_relaunch_prompt_service.dart';
import 'package:gorion_clean/features/home/widget/home_page.dart';
import 'package:gorion_clean/features/home/widget/servers_panel.dart';
import 'package:gorion_clean/features/settings/widget/settings_page.dart';
import 'package:gorion_clean/features/zapret/widget/zapret_page.dart';

abstract final class AppRoutePaths {
  static const home = '/';
  static const zapret = '/zapret';
  static const settings = '/settings';
  static const addProfile = '/modal/add-profile';
  static const profilesOverview = '/modal/profiles-overview';
  static const alert = '/modal/alert';
  static const serverSettings = '/modal/server-settings';
}

abstract final class AppRouteNames {
  static const home = 'home';
  static const zapret = 'zapret';
  static const settings = 'settings';
  static const addProfile = 'add-profile';
  static const profilesOverview = 'profiles-overview';
  static const alert = 'alert';
  static const serverSettings = 'server-settings';
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final rootNavigatorKey = ref.watch(rootNavigatorKeyProvider);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoutePaths.home,
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(
          location: state.uri.path,
          child: child,
        ),
        routes: [
          GoRoute(
            path: AppRoutePaths.home,
            name: AppRouteNames.home,
            pageBuilder: (context, state) => const NoTransitionPage<void>(
              child: HomePage(animateOnMount: false),
            ),
          ),
          GoRoute(
            path: AppRoutePaths.zapret,
            name: AppRouteNames.zapret,
            pageBuilder: (context, state) => const NoTransitionPage<void>(
              child: ZapretPage(animateOnMount: false),
            ),
          ),
          GoRoute(
            path: AppRoutePaths.settings,
            name: AppRouteNames.settings,
            pageBuilder: (context, state) => const NoTransitionPage<void>(
              child: SettingsPage(animateOnMount: false),
            ),
          ),
        ],
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: AppRoutePaths.addProfile,
        name: AppRouteNames.addProfile,
        pageBuilder: (context, state) => const AppDialogPage<void>(
          child: AddSubscriptionDialog(),
        ),
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: AppRoutePaths.profilesOverview,
        name: AppRouteNames.profilesOverview,
        pageBuilder: (context, state) => const AppDialogPage<void>(
          child: ProfilesOverviewDialog(),
        ),
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: AppRoutePaths.alert,
        name: AppRouteNames.alert,
        pageBuilder: (context, state) {
          final data = state.extra;
          if (data is! AppAlertRouteData) {
            return const AppDialogPage<void>(
              child: AppAlertDialog(
                title: 'Не удалось открыть диалог',
                message: 'Маршрут был вызван без обязательных данных.',
              ),
            );
          }
          return AppDialogPage<void>(
            child: AppAlertDialog(title: data.title, message: data.message),
          );
        },
      ),
      GoRoute(
        parentNavigatorKey: rootNavigatorKey,
        path: AppRoutePaths.serverSettings,
        name: AppRouteNames.serverSettings,
        pageBuilder: (context, state) {
          final data = state.extra;
          if (data is! ServerSettingsRouteData) {
            return const AppDialogPage<void>(
              child: AppAlertDialog(
                title: 'Не удалось открыть сервер',
                message: 'Маршрут был вызван без обязательных данных.',
              ),
            );
          }
          return AppDialogPage<void>(
            child: ServerSettingsDialog(
              server: data.server,
              outbound: data.outbound,
            ),
          );
        },
      ),
    ],
  );
});

class AppDialogPage<T> extends Page<T> {
  const AppDialogPage({
    required this.child,
    this.barrierDismissible = true,
    this.barrierColor = const Color(0x73000000),
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;
  final bool barrierDismissible;
  final Color barrierColor;

  @override
  Route<T> createRoute(BuildContext context) {
    return DialogRoute<T>(
      context: context,
      settings: this,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      builder: (dialogContext) => child,
    );
  }
}
