import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/app/windows_tray_controller.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

void main() {
  group('WindowsTrayController.iconPathForStage', () {
    test('uses the base tray icon for non-connected states', () {
      expect(
        WindowsTrayController.iconPathForStage(ConnectionStage.disconnected),
        'assets/images/tray_icon.ico',
      );
      expect(
        WindowsTrayController.iconPathForStage(ConnectionStage.failed),
        'assets/images/tray_icon.ico',
      );
      expect(
        WindowsTrayController.iconPathForStage(ConnectionStage.starting),
        'assets/images/tray_icon.ico',
      );
      expect(
        WindowsTrayController.iconPathForStage(ConnectionStage.stopping),
        'assets/images/tray_icon.ico',
      );
    });

    test('uses the connected tray icon only when connected', () {
      expect(
        WindowsTrayController.iconPathForStage(ConnectionStage.connected),
        'assets/images/tray_icon_connected.ico',
      );
    });
  });
}