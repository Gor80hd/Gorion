import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/notifier/auto_server_selection_progress.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

void main() {
  group('auto-select status formatting', () {
    test('maps automatic maintenance label to friendly text', () {
      expect(
        describeAutoSelectActivityLabel('Automatic maintenance'),
        'Проверка текущего подключения',
      );
    });

    test('describes keeping the current server', () {
      const activity = AutoSelectActivityState(
        label: 'Automatic maintenance',
        message:
            'Current server [DE] Frankfurt stayed selected after the latest URLTest and proxy probe check.',
      );

      expect(
        describeAutoSelectActivityStatus(activity),
        'Оставляем текущий сервер: 🇩🇪 Frankfurt',
      );
    });

    test('describes switching to a better server', () {
      const activity = AutoSelectActivityState(
        label: 'Automatic maintenance',
        message:
            'Auto-selector switched from [DE] Frankfurt to [NL] Amsterdam after confirming better end-to-end health and latency.',
      );

      expect(
        describeAutoSelectActivityStatus(activity),
        'Переключаемся на 🇳🇱 Amsterdam',
      );
    });

    test('describes pre-connect probing', () {
      const activity = AutoSelectActivityState(
        label: 'Pre-connect auto-select',
        message: 'Probing [NL] Amsterdam (2/5) in a detached sing-box runtime.',
      );

      expect(
        describeAutoSelectActivityStatus(activity),
        'Проверяем 🇳🇱 Amsterdam (2/5)',
      );
    });

    test('hides the chosen server before pre-connect runtime finishes', () {
      const activity = AutoSelectActivityState(
        label: 'Pre-connect auto-select',
        message:
            'Auto-selector chose [NL] Amsterdam before connect after confirming end-to-end proxy traffic.',
      );

      expect(
        describeAutoSelectActivityStatus(activity),
        'Сервер проверен, подключаемся',
      );
    });

    test('describes cached fast reconnect before runtime starts', () {
      const activity = AutoSelectActivityState(
        label: 'Pre-connect auto-select',
        message:
            'Auto-selector reused the recent successful server [NL] Amsterdam before starting sing-box.',
      );

      expect(
        describeAutoSelectActivityStatus(activity),
        'Переподключаемся к 🇳🇱 Amsterdam',
      );
    });

    test('promotes connecting summary to connected after runtime connects', () {
      const activity = AutoSelectActivityState(
        label: 'Pre-connect auto-select',
        message:
            'Auto-selector chose [NL] Amsterdam before connect after confirming end-to-end proxy traffic.',
      );

      expect(
        describeAutoSelectActivityStatus(
          activity,
          connectionStage: ConnectionStage.connected,
          activeServerTag: '[NL] Amsterdam',
        ),
        'Подключено 🇳🇱 Amsterdam',
      );
    });

    test('formats trace lines with friendly phase and summary', () {
      expect(
        describeAutoSelectTraceLine(
          '12:34:56 [Automatic maintenance] Auto-selector recovered from [DE] Frankfurt to [NL] Amsterdam after the current server failed the end-to-end proxy probe.',
        ),
        '12:34:56 [Проверка текущего подключения] Текущий сервер не прошёл проверку, переключаемся на 🇳🇱 Amsterdam',
      );
    });
  });
}
