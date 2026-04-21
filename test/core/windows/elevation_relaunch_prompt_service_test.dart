import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/windows/elevation_relaunch_prompt_service.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';

void main() {
  testWidgets('fails closed when the navigator context is unavailable', (
    WidgetTester tester,
  ) async {
    final service = DialogElevationRelaunchPromptService(
      navigatorKey: GlobalKey<NavigatorState>(),
      ensureWindowVisible: () async {},
    );

    final confirmed = await service.confirmRelaunch(
      action: PendingElevatedLaunchAction.connectTun,
    );

    expect(confirmed, isFalse);
  });
}
