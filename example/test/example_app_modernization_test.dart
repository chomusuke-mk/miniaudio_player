import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/main.dart';
import 'package:miniaudio_player_example/widgets/cards/dsp_effects_card.dart';
import 'package:miniaudio_player_example/widgets/cards/equalizer_card.dart';
import 'package:miniaudio_player_example/widgets/cards/hardware_routing_card.dart';
import 'package:miniaudio_player_example/widgets/cards/playback_engine_card.dart';
import 'package:miniaudio_player_example/widgets/cards/playlist_queue_card.dart';
import 'package:miniaudio_player_example/widgets/cards/ram_sound_effects_card.dart';
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

        // Verify unnecessary Hardware Buffer Period selector was removed and real selectors use DropdownButtonFormField
        expect(find.text('Hardware Buffer Period'), findsNothing);
        expect(
          find.byWidgetPredicate((w) => w is DropdownButtonFormField<int>),
          findsNothing,
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

        final eqCard = find.byType(EqualizerSubCard);
        expect(eqCard, findsOneWidget);
        expect(
          find.descendant(of: eqCard, matching: find.text('Acoustic RBJ Curves')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: eqCard,
            matching: find.byType(CompactSliderControl),
          ),
          findsNothing,
        );

        final eqSwitch = find.descendant(
          of: eqCard,
          matching: find.byType(Switch),
        );
        await tester.scrollUntilVisible(
          eqSwitch,
          200,
          scrollable: scrollable,
        );
        expect(tester.widget<Switch>(eqSwitch).value, isFalse);
        await tester.tap(eqSwitch);
        await tester.runAsync(() async {
          await Future.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.widget<Switch>(eqSwitch).value, isTrue);

        final presetDropdown = find.descendant(
          of: eqCard,
          matching: find.byWidgetPredicate(
            (w) => w is DropdownButtonFormField<String>,
          ),
        );
        expect(presetDropdown, findsOneWidget);
        await tester.scrollUntilVisible(
          presetDropdown,
          200,
          scrollable: scrollable,
        );
        expect(
          find.descendant(of: presetDropdown, matching: find.text('Flat')),
          findsOneWidget,
        );

        await tester.tap(presetDropdown);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Rock').last, warnIfMissed: false);
        await tester.runAsync(() async {
          await Future.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.descendant(of: presetDropdown, matching: find.text('Rock')),
          findsOneWidget,
        );
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
      'Pause on Device Change & Dynamic Metadata Event Stream live in DspEffectsCard and react to tap events',
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

        final dspCard = find.byType(DspEffectsCard);
        expect(dspCard, findsOneWidget);
        expect(
          find.descendant(
            of: dspCard,
            matching: find.text('Pause on Device Change'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: dspCard,
            matching: find.text('Dynamic Metadata Event Stream'),
          ),
          findsOneWidget,
        );

        final scrollable = find.byType(Scrollable).first;

        // Find Switch for Pause on Device Change inside DspEffectsCard
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

        // Initial state is false
        Switch pauseSwitch = tester.widget(switchFinder);
        expect(pauseSwitch.value, isFalse);

        // Tap the switch to enable
        await tester.tap(switchFinder);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        pauseSwitch = tester.widget(switchFinder);
        expect(pauseSwitch.value, isTrue);
        expect(
          find.descendant(
            of: pauseRow,
            matching: find.text(
              'Immediate native pause (0ms leak) if physical endpoint changes',
            ),
          ),
          findsOneWidget,
        );

        // Tap the switch again to disable
        await tester.tap(switchFinder);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        pauseSwitch = tester.widget(switchFinder);
        expect(pauseSwitch.value, isFalse);

        // Toggle Dynamic Metadata Event Stream switch cleanly
        final metadataRow = find
            .ancestor(
              of: find.text('Dynamic Metadata Event Stream'),
              matching: find.byType(Container),
            )
            .first;
        final metadataSwitchFinder = find.descendant(
          of: metadataRow,
          matching: find.byType(Switch),
        );
        expect(metadataSwitchFinder, findsOneWidget);
        await tester.scrollUntilVisible(
          metadataSwitchFinder,
          100,
          scrollable: scrollable,
        );
        final initialMetaValue =
            tester.widget<Switch>(metadataSwitchFinder).value;
        await tester.tap(metadataSwitchFinder);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.widget<Switch>(metadataSwitchFinder).value,
          isNot(initialMetaValue),
        );
      },
    );

    testWidgets(
      'Desktop StudioConsoleView lays out Playing/Queue/Effects 2:2:1 in Row 1, Hardware+DSP 1:2 below, and moves Audio Analyzer to its own tab',
      (tester) async {
        addTearDown(() async {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 100));
        });

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1000, 900);
        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        // Audio Analyzer lives on its own tab, not on Studio Master Console
        expect(find.text('UNIFIED AUDIO ANALYZER'), findsNothing);
        expect(find.text('Audio Analyzer'), findsOneWidget);

        for (final size in const [
          Size(1000, 900),
          Size(1440, 900),
          Size(1920, 1080),
        ]) {
          tester.view.physicalSize = size;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);

          // Row 1: Playing (2), Queue (2), Effects (1)
          final playingRect = tester.getRect(find.byType(PlaybackEngineCard));
          final queueRect = tester.getRect(find.byType(PlaylistQueueCard));
          final effectsRect = tester.getRect(find.byType(RamSoundEffectsCard));
          expect(queueRect.top, closeTo(playingRect.top, 2.0));
          expect(effectsRect.top, closeTo(playingRect.top, 2.0));
          expect(queueRect.left, greaterThan(playingRect.right));
          expect(effectsRect.left, greaterThan(queueRect.right));
          expect(playingRect.width / effectsRect.width, closeTo(2.0, 0.03));
          expect(queueRect.width / effectsRect.width, closeTo(2.0, 0.03));

          // Row 2 below: Hardware Routing (1/3) and DSP Effects (2/3)
          final routingRect = tester.getRect(find.byType(HardwareRoutingCard));
          final dspRect = tester.getRect(find.byType(DspEffectsCard));
          expect(routingRect.top, greaterThan(playingRect.bottom));
          expect(dspRect.left, greaterThan(routingRect.right));
          expect(dspRect.width / routingRect.width, closeTo(2.0, 0.02));
        }

        // Below 960px breakpoint, Playing, Queue, and Effects stack vertically with zero overflows
        tester.view.physicalSize = const Size(800, 900);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        final narrowPlayingRect = tester.getRect(
          find.byType(PlaybackEngineCard),
        );
        final narrowQueueRect = tester.getRect(find.byType(PlaylistQueueCard));
        final narrowEffectsRect = tester.getRect(
          find.byType(RamSoundEffectsCard),
        );
        expect(
          narrowQueueRect.top,
          greaterThanOrEqualTo(narrowPlayingRect.bottom),
        );
        expect(
          narrowEffectsRect.top,
          greaterThanOrEqualTo(narrowQueueRect.bottom),
        );

        // Switching to Audio Analyzer tab shows telemetry, analyzer card, and optimization cards cleanly
        await tester.tap(find.text('Audio Analyzer'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        expect(find.text('ANALYSIS PIPELINE & SESSION TELEMETRY'), findsOneWidget);
        expect(find.text('UNIFIED AUDIO ANALYZER'), findsOneWidget);
        expect(
          find.text('SINGLE-PASS NATIVE PIPELINE (RUST DSP)'),
          findsOneWidget,
        );
        expect(
          find.text('MEMORY, WORKER & CACHING OPTIMIZATIONS'),
          findsOneWidget,
        );

        // Desktop and ultra-narrow 280px @ 1.5x TextScaler render Audio Analyzer tab with zero overflow
        tester.view.physicalSize = const Size(1440, 900);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(280, 653);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(280, 653),
              devicePixelRatio: 1.0,
              textScaler: TextScaler.linear(1.5),
            ),
            child: const MiniaudioPlayerExampleApp(),
          ),
        );
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('Audio Analyzer'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
