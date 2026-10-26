import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/main.dart';
import 'package:miniaudio_player_example/widgets/common/compact_slider_overlay.dart';

Future<void> settleFrames(
  WidgetTester tester, {
  int frames = 5,
  Duration step = const Duration(milliseconds: 100),
}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const requiredViewports = <String, ({Size size, double dpr})>{
    '280x653 (Ultra-Narrow foldable outer)': (
      size: Size(280, 653),
      dpr: 2.0,
    ),
    '320x568 (Compact Mobile - iPhone SE 1st gen)': (
      size: Size(320, 568),
      dpr: 2.0,
    ),
    '360x640 (Standard Android compact)': (
      size: Size(360, 640),
      dpr: 2.0,
    ),
    '390x844 (Modern iPhone 12/13/14)': (
      size: Size(390, 844),
      dpr: 3.0,
    ),
    '412x915 (Android Standard - Pixel 7 / Galaxy S)': (
      size: Size(412, 915),
      dpr: 2.625,
    ),
  };

  const textScales = <double>[1.0, 1.3, 1.5];

  group('Challenger Suite 1: Multi-Viewport & TextScaler Stress Matrix', () {
    for (final scale in textScales) {
      for (final entry in requiredViewports.entries) {
        testWidgets(
          'Viewport ${entry.key} with TextScaler ${scale}x — Rapid Bidirectional Scrolling & Zero Overflow',
          (tester) async {
            final viewport = entry.value;
            tester.view.physicalSize = Size(
              viewport.size.width * viewport.dpr,
              viewport.size.height * viewport.dpr,
            );
            tester.view.devicePixelRatio = viewport.dpr;
            addTearDown(() async {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
              await tester.pumpWidget(const SizedBox());
              await tester.pump();
            });

            await tester.pumpWidget(
              MediaQuery(
                data: MediaQueryData(
                  size: viewport.size,
                  devicePixelRatio: viewport.dpr,
                  textScaler: TextScaler.linear(scale),
                ),
                child: const MiniaudioPlayerExampleApp(),
              ),
            );
            await tester.pump();

            // Await asynchronous track loading until mounted ready
            await tester.runAsync(() async {
              await Future.delayed(const Duration(seconds: 2));
            });
            await tester.pump();

            expect(
              find.text('miniaudio_player'),
              findsOneWidget,
              reason: 'App failed to mount ready screen on ${entry.key} @ ${scale}x',
            );

            expect(
              tester.takeException(),
              isNull,
              reason: 'Exception on initial mount for ${entry.key} @ ${scale}x',
            );

            final scrollables = find.byType(Scrollable);
            expect(scrollables, findsWidgets);
            final verticalScrollable = scrollables.first;

            // Rapid scroll all the way down across all 6 cards
            for (int i = 0; i < 10; i++) {
              await tester.drag(verticalScrollable, const Offset(0, -350));
              await tester.pump();
              expect(
                tester.takeException(),
                isNull,
                reason: 'Overflow during downward scroll step $i on ${entry.key} @ ${scale}x',
              );
            }

            // Rapid scroll back to the top
            for (int i = 0; i < 10; i++) {
              await tester.drag(verticalScrollable, const Offset(0, 350));
              await tester.pump();
              expect(
                tester.takeException(),
                isNull,
                reason: 'Overflow during upward scroll step $i on ${entry.key} @ ${scale}x',
              );
            }

            await settleFrames(tester, frames: 3);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  group('Challenger Suite 2: Dropdown & Control Tap & Selection Interactions', () {
    testWidgets(
      'Verify all dropdowns and sleek overlays can be tapped and manipulated without exceptions',
      (tester) async {
        tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(() async {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        });

        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump();

        final scrollable = find.byType(Scrollable).first;

        // 1. Crossfeed Mode Dropdown
        final crossfeedDropdown = find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<CrossfeedMode>,
        );
        expect(crossfeedDropdown, findsOneWidget);
        await tester.scrollUntilVisible(crossfeedDropdown, 200, scrollable: scrollable);
        await tester.tap(crossfeedDropdown);
        await settleFrames(tester, frames: 5);
        final crossfeedItem = find.text('Moffat-Bauer (4.5 dB)').last;
        await tester.tap(crossfeedItem, warnIfMissed: false);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        // 2. Buffer Size Dropdown
        final bufDropdown = find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<int>,
        );
        expect(bufDropdown, findsOneWidget);
        await tester.scrollUntilVisible(bufDropdown, 200, scrollable: scrollable);
        await tester.tap(bufDropdown);
        await settleFrames(tester, frames: 5);
        final bufItem = find.text('512 frames (~11.6ms @ 44.1kHz)').last;
        await tester.tap(bufItem, warnIfMissed: false);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        // 3. Audio Device Dropdown
        final devDropdown = find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<AudioDevice>,
        );
        expect(devDropdown, findsOneWidget);
        await tester.scrollUntilVisible(devDropdown, 200, scrollable: scrollable);
        await tester.tap(devDropdown);
        await settleFrames(tester, frames: 5);
        final devItems = find.byWidgetPredicate(
          (w) => w is DropdownMenuItem<AudioDevice>,
        );
        expect(devItems, findsWidgets);
        await tester.tap(devItems.first, warnIfMissed: false);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        // 4. EQ Preset ChoiceChip Selection
        final rockChipFinder = find.widgetWithText(ChoiceChip, 'Rock');
        await tester.scrollUntilVisible(rockChipFinder, 200, scrollable: scrollable);
        await tester.tap(rockChipFinder);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        // 5. Silence Skip Mode Dropdown
        final skipCard = find.ancestor(
          of: find.text('Smart Silence Skipping'),
          matching: find.byType(Card),
        );
        final skipSwitch = find.descendant(
          of: skipCard,
          matching: find.byType(Switch),
        );
        await tester.scrollUntilVisible(skipSwitch, 200, scrollable: scrollable);
        await tester.tap(skipSwitch);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        final silenceDropdown = find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<SilenceSkipMode>,
        );
        expect(silenceDropdown, findsOneWidget);
        await tester.scrollUntilVisible(silenceDropdown, 200, scrollable: scrollable);
        await tester.tap(silenceDropdown);
        await settleFrames(tester, frames: 5);
        final silenceItem = find.text('Trim Edges (Intro & Outro)').last;
        await tester.tap(silenceItem, warnIfMissed: false);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        // 6. Sleek CompactSliderControl Overlay Interaction
        final sliderControls = find.byType(CompactSliderControl);
        expect(sliderControls, findsWidgets);
        await tester.scrollUntilVisible(sliderControls.first, 200, scrollable: scrollable);
        await tester.tap(sliderControls.first);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        // Tap again to toggle closed
        await tester.tap(sliderControls.first);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Challenger Suite 3: Switch Toggling Stress & State Validation', () {
    testWidgets('Skip Silence Switch: ON/OFF toggling and rapid toggle stress', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      await tester.pumpWidget(const MiniaudioPlayerExampleApp());
      await tester.pump();
      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      final scrollable = find.byType(Scrollable).first;
      final skipCard = find.ancestor(
        of: find.text('Smart Silence Skipping'),
        matching: find.byType(Card),
      );
      final skipSwitch = find.descendant(
        of: skipCard,
        matching: find.byType(Switch),
      );
      await tester.scrollUntilVisible(skipSwitch, 200, scrollable: scrollable);

      // Verify initially OFF
      expect(find.descendant(of: skipCard, matching: find.text('OFF')), findsOneWidget);

      // Toggle ON
      await tester.tap(skipSwitch);
      await settleFrames(tester, frames: 5);
      expect(find.descendant(of: skipCard, matching: find.text('ON')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Verify subcontrols enabled (IgnorePointer is NOT ignoring)
      final subcolumnIgnorePointer = find.descendant(
        of: skipCard,
        matching: find.byWidgetPredicate(
          (w) => w is IgnorePointer && w.ignoring == false,
        ),
      );
      expect(subcolumnIgnorePointer, findsWidgets);

      // Toggle OFF
      await tester.tap(skipSwitch);
      await settleFrames(tester, frames: 5);
      expect(find.descendant(of: skipCard, matching: find.text('OFF')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Rapid toggling 6 times
      for (int i = 0; i < 6; i++) {
        await tester.tap(skipSwitch);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settleFrames(tester, frames: 5);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Visualizer Switch: ON/OFF toggling and rapid toggle stress', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      await tester.pumpWidget(const MiniaudioPlayerExampleApp());
      await tester.pump();
      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      final scrollable = find.byType(Scrollable).first;
      final visualizerCard = find.ancestor(
        of: find.text('Real-Time Reactive Visualizer'),
        matching: find.byType(Card),
      );
      final visualizerSwitch = find.descendant(
        of: visualizerCard,
        matching: find.byType(Switch),
      );
      await tester.scrollUntilVisible(visualizerSwitch, 200, scrollable: scrollable);

      // Verify initially OFF
      expect(find.descendant(of: visualizerCard, matching: find.text('OFF')), findsOneWidget);

      // Toggle ON
      await tester.tap(visualizerSwitch);
      await settleFrames(tester, frames: 5);
      expect(find.descendant(of: visualizerCard, matching: find.text('ON')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Toggle OFF
      await tester.tap(visualizerSwitch);
      await settleFrames(tester, frames: 5);
      expect(find.descendant(of: visualizerCard, matching: find.text('OFF')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Rapid toggling 6 times
      for (int i = 0; i < 6; i++) {
        await tester.tap(visualizerSwitch);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settleFrames(tester, frames: 5);
      expect(tester.takeException(), isNull);
    });
  });

  group('Challenger Suite 4: Extreme Combined Adversarial Stress', () {
    testWidgets(
      'Ultra-Narrow 280x653 Foldable with 1.5x TextScaler — Full Interactions & Rapid Scrolling',
      (tester) async {
        const viewportSize = Size(280, 653);
        const dpr = 2.0;
        tester.view.physicalSize = Size(viewportSize.width * dpr, viewportSize.height * dpr);
        tester.view.devicePixelRatio = dpr;
        addTearDown(() async {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        });

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: viewportSize,
              devicePixelRatio: dpr,
              textScaler: TextScaler.linear(1.5),
            ),
            child: const MiniaudioPlayerExampleApp(),
          ),
        );
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump();

        expect(find.text('miniaudio_player'), findsOneWidget);
        expect(tester.takeException(), isNull);

        final scrollable = find.byType(Scrollable).first;

        // Rapid scroll down
        for (int i = 0; i < 8; i++) {
          await tester.drag(scrollable, const Offset(0, -300));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }

        // Toggle Skip Silence ON under 1.5x TextScaler
        final skipCard = find.ancestor(
          of: find.text('Smart Silence Skipping'),
          matching: find.byType(Card),
        );
        final skipSwitch = find.descendant(
          of: skipCard,
          matching: find.byType(Switch),
        );
        await tester.scrollUntilVisible(skipSwitch, 200, scrollable: scrollable);
        await tester.tap(skipSwitch);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        // Select mode in Skip Silence
        final silenceDropdown = find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<SilenceSkipMode>,
        );
        await tester.scrollUntilVisible(silenceDropdown, 200, scrollable: scrollable);
        await tester.tap(silenceDropdown);
        await settleFrames(tester, frames: 5);
        final silenceItem = find.text('All (Edges + In-Between Pauses)').last;
        await tester.tap(silenceItem, warnIfMissed: false);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        // Toggle Visualizer OFF under 1.5x TextScaler
        final visualizerCard = find.ancestor(
          of: find.text('Real-Time Reactive Visualizer'),
          matching: find.byType(Card),
        );
        final visualizerSwitch = find.descendant(
          of: visualizerCard,
          matching: find.byType(Switch),
        );
        await tester.scrollUntilVisible(visualizerSwitch, 200, scrollable: scrollable);
        await tester.tap(visualizerSwitch);
        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);

        // Rapid scroll back to top under 1.5x TextScaler
        for (int i = 0; i < 8; i++) {
          await tester.drag(scrollable, const Offset(0, 300));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }

        await settleFrames(tester, frames: 5);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
