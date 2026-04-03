import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gorion_clean/app/app.dart';

void main() {
  testWidgets('app renders subscription workspace', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: GorionApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Local sing-box workspace'), findsOneWidget);
  });
}
