import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:p2wlan_flutter_client/shared/widgets/app_notice.dart';

void main() {
  testWidgets('notice is upper center, replaces previous and dismisses', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showAppNotice(context, content: const Text('Saved')),
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.text('Saved')).dy, lessThan(200));
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsNothing);
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('notice content keeps its intrinsic height', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppNotice(
                context,
                content: DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.red),
                  // Deliberately leave the Column at its default max size to
                  // ensure the notice constrains arbitrary caller content.
                  child: Column(
                    children: [const Text('无法登录'), const Text('控制服务器返回了错误')],
                  ),
                ),
              ),
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();

    final banner = find
        .ancestor(
          of: find.text('控制服务器返回了错误'),
          matching: find.byType(DecoratedBox),
        )
        .last;
    expect(tester.getRect(banner).height, lessThan(120));
  });
}
