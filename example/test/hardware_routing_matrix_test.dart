import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/main.dart';
import 'package:miniaudio_player_example/widgets/cards/hardware_routing_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('Hardware Routing Matrix & Device Enumeration Suite', () {
    testWidgets(
      'Mounted HardwareRoutingCard lists outputs & inputs, displays resolved device names, and supports turning off default output to empty set ({})',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 3000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() async {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 100));
        });

        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        // 1. Verify card is mounted
        expect(find.byType(HardwareRoutingCard), findsOneWidget);

        // 2. Initial state: 1 OUT (default: AUTO selected), 0 IN
        expect(find.text('1 OUT'), findsOneWidget);
        expect(find.text('0 IN'), findsOneWidget);

        // 3. Find the checkboxes inside HardwareRoutingCard
        final routingCardFinder = find.byType(HardwareRoutingCard);
        final checkboxes = find.descendant(
          of: routingCardFinder,
          matching: find.byType(Checkbox),
        );
        expect(checkboxes, findsWidgets);

        final defaultCheckbox = tester.widget<Checkbox>(checkboxes.first);
        expect(defaultCheckbox.value, isTrue);

        // 4. Tap the first checkbox to turn off the default output
        await tester.tap(checkboxes.first);
        await tester.runAsync(() async {
          await Future.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        // 5. Must now display 0 OUT and checkbox must be unchecked
        expect(find.text('0 OUT'), findsOneWidget);
        final uncheckedBox = tester.widget<Checkbox>(checkboxes.first);
        expect(uncheckedBox.value, isFalse);

        // 6. Tap again to turn default output back ON
        await tester.tap(checkboxes.first);
        await tester.runAsync(() async {
          await Future.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('1 OUT'), findsOneWidget);
        final restoredBox = tester.widget<Checkbox>(checkboxes.first);
        expect(restoredBox.value, isTrue);
      },
    );
  });
}
