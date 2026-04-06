import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gorion_clean/app/shell.dart';

void main() {
  testWidgets('app shell renders home content', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: AppShell(child: SizedBox(key: Key('home-child'))),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byKey(const Key('home-child')), findsOneWidget);
    expect(find.text('gorion'), findsOneWidget);
  });
}
