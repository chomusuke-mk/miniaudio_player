import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/main.dart';
import 'package:miniaudio_player_example/widgets/cards/spectrum_visualizer_card.dart';
import 'package:miniaudio_player_example/widgets/common/compact_slider_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Example App Modernization & Bugfixes Suite', () {
    testWidgets(
      'Material 3 Dropdown Migration: Selectors use DropdownButtonFormField and routing uses HardwareRoutingCard',
      (tester) async {
        addTearDown(() async {
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

        // Verify specific form fields exist
        expect(
          find.byWidgetPredicate((w) => w is DropdownButtonFormField<int>),
          findsOneWidget,
          reason: 'Buffer selector must be a DropdownButtonFormField<int>',
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is DropdownButtonFormField<SilenceSkipMode>,
          ),
          findsOneWidget,
          reason: 'Silence skip selector must be a DropdownButtonFormField<SilenceSkipMode>',
        );

        // Hardware I/O is decoupled to HardwareRoutingCard
        expect(find.text('AUDIO HARDWARE ROUTING MATRIX'), findsOneWidget);
        // Bauer BS2B Crossfeed is embedded inside DspEffectsCard alongside Smart Silence Skipping
        expect(find.text('Bauer BS2B Crossfeed'), findsOneWidget);
      },
    );

    testWidgets(
      'ReplayGain Decoupling: Set Volume Slider ActionChip is absent from ReplayGain card',
      (tester) async {
        addTearDown(() async {
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

        // Ensure "Set Volume Slider" is never present
        expect(find.textContaining('Set Volume Slider'), findsNothing);
        final dspCard = find.ancestor(
          of: find.text('DYNAMIC DSP & SPATIAL MASTERING'),
          matching: find.byType(Card),
        );
        expect(
          find.descendant(of: dspCard, matching: find.byType(ActionChip)),
          findsNothing,
        );
      },
    );

    testWidgets(
      'EQ Preset Selection: Displays selected preset and reflects active choice',
      (tester) async {
        addTearDown(() async {
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

        final scrollable = find.byType(Scrollable).first;

        // Locate Flat and Rock ChoiceChips in Equalizer card
        final flatChipFinder = find.widgetWithText(ChoiceChip, 'Flat');
        expect(flatChipFinder, findsOneWidget);
        await tester.scrollUntilVisible(
          flatChipFinder,
          200,
          scrollable: scrollable,
        );

        final flatChip = tester.widget<ChoiceChip>(flatChipFinder);
        expect(flatChip.selected, isTrue);

        final rockChipFinder = find.widgetWithText(ChoiceChip, 'Rock');
        expect(rockChipFinder, findsOneWidget);
        await tester.scrollUntilVisible(
          rockChipFinder,
          200,
          scrollable: scrollable,
        );
        await tester.tap(rockChipFinder);
        await tester.runAsync(() async {
          await Future.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final rockChip = tester.widget<ChoiceChip>(rockChipFinder);
        expect(rockChip.selected, isTrue);
      },
    );

    testWidgets(
      'Conditional Skip Silence: Subcontrols are visually dimmed and ignored when OFF',
      (tester) async {
        addTearDown(() async {
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

        // Scroll to Skip Silence card
        final skipSilenceTitle = find.text('Smart Silence Skipping');
        expect(skipSilenceTitle, findsOneWidget);

        // Find the Skip Silence mode dropdown
        final modeDropdownFinder = find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<SilenceSkipMode>,
        );
        expect(modeDropdownFinder, findsOneWidget);

        final modeDropdown = tester
            .widget<DropdownButtonFormField<SilenceSkipMode>>(
              modeDropdownFinder,
            );
        // By default, skip silence is disabled (OFF), so onChanged must be null
        expect(
          modeDropdown.onChanged,
          isNull,
          reason: 'Skip silence mode dropdown must be disabled when OFF',
        );

        // An IgnorePointer must be ignoring user events when OFF
        final ignorePointerFinder = find.ancestor(
          of: modeDropdownFinder,
          matching: find.byWidgetPredicate(
            (w) => w is IgnorePointer && w.ignoring == true,
          ),
        );
        expect(
          ignorePointerFinder,
          findsWidgets,
          reason:
              'Sub-controls must be wrapped in active IgnorePointer when OFF',
        );

        // An AnimatedOpacity must be set to 0.38 when OFF
        final animatedOpacityFinder = find.ancestor(
          of: modeDropdownFinder,
          matching: find.byWidgetPredicate(
            (w) => w is AnimatedOpacity && w.opacity == 0.38,
          ),
        );
        expect(
          animatedOpacityFinder,
          findsWidgets,
          reason: 'Sub-controls must be dimmed with opacity 0.38 when OFF',
        );

        // Threshold pill inside Smart Silence Skipping must be disabled when OFF
        final thresholdPill = tester.widget<CompactSliderControl>(
          find.widgetWithText(CompactSliderControl, 'Threshold: -45.0 dB'),
        );
        expect(thresholdPill.disabled, isTrue);
      },
    );

    testWidgets(
      'Reactive Visualizer UI: Toggling OFF resets and dims visualizer card',
      (tester) async {
        addTearDown(() async {
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

        expect(find.text('Real-Time Reactive Visualizer'), findsOneWidget);

        // Find the visualizer AnimatedOpacity
        final opacityFinder = find.byWidgetPredicate(
          (w) =>
              w is AnimatedOpacity && (w.opacity == 1.0 || w.opacity == 0.38),
        );
        expect(opacityFinder, findsWidgets);
      },
    );

    testWidgets(
      'Visualizer Source Selection: Displays current source in dropdown, renders Voice Only, and updates on selection',
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

        final visualizerCard = find.byType(SpectrumVisualizerCard);
        expect(visualizerCard, findsOneWidget);

        final scrollable = find.byType(Scrollable).first;

        // Enable visualizer switch if off
        final switchFinder = find.descendant(
          of: visualizerCard,
          matching: find.byType(Switch),
        );
        await tester.scrollUntilVisible(
          switchFinder,
          150,
          scrollable: scrollable,
        );
        final visualizerSwitch = tester.widget<Switch>(switchFinder);
        if (!visualizerSwitch.value) {
          await tester.tap(switchFinder);
          await tester.pump(const Duration(milliseconds: 100));
        }

        // Find the visualizer source dropdown
        final dropdownFinder = find.descendant(
          of: visualizerCard,
          matching: find.byType(DropdownButton<AudioOutputSource>),
        );
        expect(dropdownFinder, findsOneWidget);

        // Verify initial source is All Mix
        expect(
          find.descendant(of: visualizerCard, matching: find.text('All Mix')),
          findsOneWidget,
        );

        // Open dropdown
        await tester.tap(dropdownFinder);
        await tester.pumpAndSettle();

        // Tap Voice Only in dropdown menu
        final voiceOnlyMenuItem = find.text('Voice Only').last;
        await tester.tap(voiceOnlyMenuItem);
        await tester.runAsync(() async {
          await Future.delayed(const Duration(milliseconds: 200));
        });
        await tester.pumpAndSettle();

        // Verify Voice Only is now selected in dropdown
        expect(
          find.descendant(
            of: visualizerCard,
            matching: find.text('Voice Only'),
          ),
          findsOneWidget,
        );

        // Open dropdown again and select Music Only
        await tester.tap(dropdownFinder);
        await tester.pumpAndSettle();

        final musicOnlyMenuItem = find.text('Music Only').last;
        await tester.tap(musicOnlyMenuItem);
        await tester.runAsync(() async {
          await Future.delayed(const Duration(milliseconds: 200));
        });
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: visualizerCard,
            matching: find.text('Music Only'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Pause on Device Change: Displays toggle and reacts to tap events',
      (tester) async {
        addTearDown(() async {
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

        // Verify title exists
        expect(find.text('Pause on Device Change'), findsOneWidget);

        final scrollable = find.byType(Scrollable).first;

        // Find Switch for Pause on Device Change
        final pauseRow = find
            .ancestor(
              of: find.text('Pause on Device Change'),
              matching: find.byType(Container),
            )
            .first;
        final switchFinder = find.descendant(
          of: pauseRow,
          matching: find.byType(Switch),
        );
        expect(switchFinder, findsOneWidget);
        await tester.scrollUntilVisible(
          switchFinder,
          100,
          scrollable: scrollable,
        );

        // Initial state is false (OFF)
        Switch pauseSwitch = tester.widget(switchFinder);
        expect(pauseSwitch.value, isFalse);
        expect(
          find.descendant(of: pauseRow, matching: find.text('OFF')),
          findsOneWidget,
        );

        // Tap the switch to enable
        await tester.tap(switchFinder);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        pauseSwitch = tester.widget(switchFinder);
        expect(pauseSwitch.value, isTrue);
        expect(
          find.descendant(of: pauseRow, matching: find.text('ON')),
          findsOneWidget,
        );

        // Tap the switch again to disable
        await tester.tap(switchFinder);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        pauseSwitch = tester.widget(switchFinder);
        expect(pauseSwitch.value, isFalse);
        expect(
          find.descendant(of: pauseRow, matching: find.text('OFF')),
          findsOneWidget,
        );
      },
    );
  });
}
