import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/state/update_value.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';

void main() {
  test('absent update value keeps the original field untouched', () {
    const value = UpdateValue<String?>.absent();

    expect(value.isPresent, isFalse);
  });

  test('present update value can explicitly carry null', () {
    const value = UpdateValue<String?>.value(null);

    expect(value.isPresent, isTrue);
    expect(value.value, isNull);
  });

  test('DashboardState copyWith clears nullable fields through update values', () {
    final state = DashboardState(
      selectedServerTag: 'server-a',
      statusMessage: 'ready',
    );

    final next = state.copyWith(
      selectedServerTagUpdate: const UpdateValue<String?>.value(null),
      statusMessageUpdate: const UpdateValue<String?>.value(null),
    );

    expect(next.selectedServerTag, isNull);
    expect(next.statusMessage, isNull);
  });

  test('ZapretState copyWith clears nullable fields through update values', () {
    const state = ZapretState(
      statusMessage: 'running',
      errorMessage: 'warning',
    );

    final next = state.copyWith(
      statusMessageUpdate: const UpdateValue<String?>.value(null),
      errorMessageUpdate: const UpdateValue<String?>.value(null),
    );

    expect(next.statusMessage, isNull);
    expect(next.errorMessage, isNull);
  });
}
