import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

void main() {
  test(
    'selectSingboxRuntimeBackend keeps mixed and system proxy in the user session',
    () {
      expect(
        selectSingboxRuntimeBackend(
          mode: RuntimeMode.mixed,
          privilegedHelperProvisioned: true,
        ),
        SingboxRuntimeBackend.local,
      );
      expect(
        selectSingboxRuntimeBackend(
          mode: RuntimeMode.systemProxy,
          privilegedHelperProvisioned: true,
        ),
        SingboxRuntimeBackend.local,
      );
    },
  );

  test('selectSingboxRuntimeBackend uses helper only for TUN', () {
    expect(
      selectSingboxRuntimeBackend(
        mode: RuntimeMode.tun,
        privilegedHelperProvisioned: true,
      ),
      SingboxRuntimeBackend.privilegedHelper,
    );
    expect(
      selectSingboxRuntimeBackend(
        mode: RuntimeMode.tun,
        privilegedHelperProvisioned: false,
      ),
      SingboxRuntimeBackend.local,
    );
  });
}
