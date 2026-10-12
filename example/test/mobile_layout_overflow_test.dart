import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player_example/main.dart';

void main() {
  const targetViewports = <String, ({Size size, double dpr})>{
    '390x844 (Standard Mobile - iPhone 12/13/14)': (
      size: Size(390, 844),
      dpr: 3.0,
    ),
    '320x568 (Compact Mobile - iPhone SE 1st gen)': (
      size: Size(320, 568),
      dpr: 2.0,
    ),
    '280x653 (Ultra-Narrow - Galaxy Z Fold outer)': (
      size: Size(280, 653),
      dpr: 2.0,
    ),
    '360x640 (Android Compact - Budget Standard)': (
      size: Size(360, 640),
      dpr: 2.0,
    ),
    '412x915 (Android Standard - Pixel 7 / Galaxy S)': (
      size: Size(412, 915),
      dpr: 2.625,
    ),
  };

  for (final entry in targetViewports.entries) {
    testWidgets(
      'Mounted UI tree renders with zero RenderFlex overflows on ${entry.key}',
      (tester) async {
        final viewport = entry.value;
        tester.view.physicalSize = Size(
          viewport.size.width * viewport.dpr,
          viewport.size.height * viewport.dpr,
        );
        tester.view.devicePixelRatio = viewport.dpr;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        // 1. Initial pump
        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();

        // 2. Authentically await asynchronous track initialization and loading
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump();

        // 3. Confirm that the application reached mounted ready state
        expect(
          find.text('miniaudio_player Demo'),
          findsOneWidget,
          reason: 'App failed to mount the main screen (_isReady remained false)',
        );

        // 4. Systematically scroll through all cards to trigger build & layout
        final scrollables = find.byType(Scrollable);
        expect(scrollables, findsWidgets);
        final verticalScrollable = scrollables.first;
        for (int i = 0; i < 8; i++) {
          await tester.drag(verticalScrollable, const Offset(0, -300));
          await tester.pump();
        }

        // 5. Assert zero RenderFlex layout overflow exceptions occurred
        final exception = tester.takeException();
        expect(
          exception,
          isNull,
          reason: 'Mounted UI threw layout overflow exception on ${entry.key}',
        );
      },
    );
  }
}
