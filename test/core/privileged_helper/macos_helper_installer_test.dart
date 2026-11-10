import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/privileged_helper/macos_helper_installer.dart';
import 'package:gorion_clean/core/privileged_helper/privileged_helper_protocol.dart';

void main() {
  group('MacosPrivilegedHelperInstaller.buildPlist', () {
    test('points the daemon at the current executable in helper mode', () {
      final plist = MacosPrivilegedHelperInstaller.buildPlist(
        executablePath: '/Applications/Gorion.app/Contents/MacOS/gorion',
      );

      expect(
        plist,
        contains('<string>$gorionPrivilegedHelperMacosLabel</string>'),
      );
      expect(
        plist,
        contains(
          '<string>/Applications/Gorion.app/Contents/MacOS/gorion</string>',
        ),
      );
      expect(plist, contains('<string>$gorionPrivilegedHelperArg</string>'));
      expect(plist, contains('<key>RunAtLoad</key>'));
      expect(plist, contains('<key>KeepAlive</key>'));
    });

    test('escapes XML entities in the executable path', () {
      final plist = MacosPrivilegedHelperInstaller.buildPlist(
        executablePath: '/Applications/Gorion & Co.app/Contents/MacOS/app',
      );

      expect(plist, contains('Gorion &amp; Co.app'));
      expect(plist, isNot(contains('Gorion & Co.app')));
    });
  });

  group('MacosPrivilegedHelperInstaller.shellQuote', () {
    test('wraps values in single quotes and escapes embedded quotes', () {
      expect(
        MacosPrivilegedHelperInstaller.shellQuote('/plain/path'),
        "'/plain/path'",
      );
      expect(
        MacosPrivilegedHelperInstaller.shellQuote("/path/it's/here"),
        "'/path/it'\\''s/here'",
      );
    });
  });

  group('MacosPrivilegedHelperInstaller install flow', () {
    test(
      'maps a cancelled password prompt to HelperInstallCancelledException',
      () async {
        Future<ProcessResult> fakeRunner(
          String executable,
          List<String> arguments, {
          Duration timeout = const Duration(seconds: 15),
        }) async {
          return ProcessResult(0, -128, '', 'User canceled.');
        }

        final installer = MacosPrivilegedHelperInstaller(
          processRunner: fakeRunner,
        );

        await expectLater(
          installer.install(
            executablePath: '/tmp/Gorion.app/Contents/MacOS/app',
          ),
          throwsA(isA<HelperInstallCancelledException>()),
        );
      },
      testOn: 'mac-os',
    );

    test('surfaces osascript failures with details', () async {
      Future<ProcessResult> fakeRunner(
        String executable,
        List<String> arguments, {
        Duration timeout = const Duration(seconds: 15),
      }) async {
        return ProcessResult(0, 1, '', 'bootstrap failed: not privileged');
      }

      final installer = MacosPrivilegedHelperInstaller(
        processRunner: fakeRunner,
      );

      await expectLater(
        installer.install(executablePath: '/tmp/Gorion.app/Contents/MacOS/app'),
        throwsA(
          isA<ProcessException>().having(
            (error) => error.message,
            'message',
            contains('not privileged'),
          ),
        ),
      );
    }, testOn: 'mac-os');
  });
}
