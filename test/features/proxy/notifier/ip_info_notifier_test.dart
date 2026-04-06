import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';
import 'package:gorion_clean/features/proxy/notifier/ip_info_notifier.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

void main() {
  test('re-runs routed IP lookup when the active server changes', () async {
    final lookupService = _FakeIpInfoLookupService();
    final controller = _TestDashboardController(
      initialState: const DashboardState(
        bootstrapping: false,
        connectionStage: ConnectionStage.connected,
        runtimeSession: RuntimeSession(
          profileId: 'profile-1',
          mode: RuntimeMode.systemProxy,
          binaryPath: 'sing-box.exe',
          configPath: 'config.json',
          controllerPort: 9090,
          mixedPort: 2080,
          secret: 'secret',
          manualSelectorTag: 'manual',
          autoGroupTag: 'auto',
        ),
        activeServerTag: 'server-a',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        dashboardControllerProvider.overrideWith((ref) => controller),
        ipInfoLookupServiceProvider.overrideWithValue(lookupService),
      ],
    );
    addTearDown(container.dispose);

    final first = await container.read(ipInfoNotifierProvider.future);
    expect(first.ip, '203.0.113.1');
    expect(lookupService.proxyLookupCalls, 1);

    controller.emit(controller.state.copyWith(activeServerTag: 'server-b'));

    final second = await container.read(ipInfoNotifierProvider.future);
    expect(second.ip, '203.0.113.2');
    expect(lookupService.proxyLookupCalls, 2);
  });
}

class _TestDashboardController extends DashboardController {
  _TestDashboardController({required DashboardState initialState})
    : super(
        repository: ProfileRepository(),
        runtimeService: SingboxRuntimeService(),
        autoSelectSettingsRepository: AutoSelectSettingsRepository(),
        autoSelectPreconnectService: AutoSelectPreconnectService(
          settingsRepository: AutoSelectSettingsRepository(),
        ),
        autoSelectorService: AutoSelectorService(),
        initialState: initialState,
        loadOnInit: false,
      );

  void emit(DashboardState nextState) {
    state = nextState;
  }
}

class _FakeIpInfoLookupService extends IpInfoLookupService {
  int proxyLookupCalls = 0;

  @override
  Future<IpInfo> lookupProxy({
    required String userAgent,
    required int proxyPort,
  }) async {
    proxyLookupCalls += 1;
    return IpInfo(
      ip: '203.0.113.$proxyLookupCalls',
      countryCode: 'DK',
      country: 'Denmark',
      region: 'Capital Region',
      city: proxyLookupCalls == 1 ? 'Amsterdam' : 'Copenhagen',
    );
  }
}
