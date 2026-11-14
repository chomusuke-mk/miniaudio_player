import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/controllers/audio_engine_controller.dart';
import 'package:miniaudio_player_example/theme/studio_theme.dart';
import 'package:miniaudio_player_example/widgets/cards/dsp_effects_card.dart';
import 'package:miniaudio_player_example/widgets/cards/equalizer_card.dart';
import 'package:miniaudio_player_example/widgets/cards/playback_engine_card.dart';
import 'package:miniaudio_player_example/widgets/common/compact_slider_overlay.dart';
import 'package:miniaudio_player_example/widgets/common/dsp_sub_card.dart';
import 'package:miniaudio_player_example/widgets/common/studio_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('DspEffectsCard Bauer BS2B & Smart Silence Shared Card Layout', () {
    late AudioEngineController controller;

    setUp(() {
      controller = AudioEngineController();
    });

    tearDown(() {
      controller.dispose();
    });

    Future<void> pumpDspCard(
      WidgetTester tester, {
      Size size = const Size(800, 900),
      double textScale = 1.0,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.darkTheme,
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: DspEffectsCard(controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    Finder subCardFor(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(DspSubCard),
    );

    Finder subCardBoxFor(String title) => find
        .ancestor(of: find.text(title), matching: find.byType(Container))
        .first;

    testWidgets(
      'Places Smart Silence, Bauer BS2B Crossfeed, Stereo Widener & Algorithmic Reverb 1/4 each on wide width with shared DspSubCard design and pill controls',
      (tester) async {
        await pumpDspCard(tester, size: const Size(900, 900));

        expect(find.text('DYNAMIC DSP & SPATIAL MASTERING'), findsOneWidget);
        expect(find.text('Smart Silence Skipping'), findsOneWidget);
        expect(find.text('Bauer BS2B Crossfeed'), findsOneWidget);
        expect(find.text('Stereo Widener'), findsOneWidget);
        expect(find.text('Algorithmic Reverb'), findsOneWidget);
        expect(find.text('ISO 266 10-Band Equalizer'), findsOneWidget);
        expect(find.byType(EqualizerSubCard), findsOneWidget);
        expect(find.byType(DspSubCard), findsNWidgets(5));
        expect(find.byType(ChoiceChip), findsNothing);
        expect(
          find.text('Left and Right audio channels are completely isolated'),
          findsNothing,
        );

        final silenceSubCard = subCardFor('Smart Silence Skipping');
        final crossfeedSubCard = subCardFor('Bauer BS2B Crossfeed');
        final widenerSubCard = subCardFor('Stereo Widener');
        final reverbSubCard = subCardFor('Algorithmic Reverb');
        final eqSubCard = subCardFor('ISO 266 10-Band Equalizer');
        expect(silenceSubCard, findsOneWidget);
        expect(crossfeedSubCard, findsOneWidget);
        expect(widenerSubCard, findsOneWidget);
        expect(reverbSubCard, findsOneWidget);
        expect(eqSubCard, findsOneWidget);

        final silenceBox = tester.getRect(subCardBoxFor('Smart Silence Skipping'));
        final crossfeedBox = tester.getRect(subCardBoxFor('Bauer BS2B Crossfeed'));
        final widenerBox = tester.getRect(subCardBoxFor('Stereo Widener'));
        final reverbBox = tester.getRect(subCardBoxFor('Algorithmic Reverb'));
        final eqBox = tester.getRect(subCardBoxFor('ISO 266 10-Band Equalizer'));
        // All 4 sit in the same Row, each occupying ~1/4 width with matched height
        expect(crossfeedBox.top, closeTo(silenceBox.top, 0.5));
        expect(widenerBox.top, closeTo(silenceBox.top, 0.5));
        expect(reverbBox.top, closeTo(silenceBox.top, 0.5));
        expect(crossfeedBox.left, greaterThan(silenceBox.right));
        expect(widenerBox.left, greaterThan(crossfeedBox.right));
        expect(reverbBox.left, greaterThan(widenerBox.right));
        expect(crossfeedBox.width, closeTo(silenceBox.width, 1.5));
        expect(widenerBox.width, closeTo(silenceBox.width, 1.5));
        expect(reverbBox.width, closeTo(silenceBox.width, 1.5));
        expect(crossfeedBox.height, closeTo(silenceBox.height, 0.5));
        expect(widenerBox.height, closeTo(silenceBox.height, 0.5));
        expect(reverbBox.height, closeTo(silenceBox.height, 0.5));
        // Equalizer spans full width (1) on Row 2 below the 4 mastering subcards
        expect(eqBox.top, greaterThanOrEqualTo(silenceBox.bottom));
        expect(eqBox.left, closeTo(silenceBox.left, 0.5));
        expect(eqBox.right, closeTo(reverbBox.right, 0.5));

        // Unboxed pills: only ONE #070B14 container encloses Bauer BS2B Crossfeed (its own DspSubCard)
        final bs2bDarkContainers = find.ancestor(
          of: find.text('Lowpass Cutoff: 700 Hz'),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color ==
                    const Color(0xFF070B14),
          ),
        );
        expect(bs2bDarkContainers, findsOneWidget);

        // No StudioBadge on Bauer BS2B Crossfeed; uses Preset dropdown + stacked pills directly
        expect(
          find.descendant(
            of: crossfeedSubCard,
            matching: find.byType(StudioBadge),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: crossfeedSubCard,
            matching: find.byWidgetPredicate(
              (w) => w is InputDecorator && w.decoration.labelText == 'Preset',
            ),
          ),
          findsOneWidget,
        );

        final cutoffPill = find.descendant(
          of: crossfeedSubCard,
          matching: find.widgetWithText(
            CompactSliderControl,
            'Lowpass Cutoff: 700 Hz',
          ),
        );
        final crossfeedPill = find.descendant(
          of: crossfeedSubCard,
          matching: find.widgetWithText(
            CompactSliderControl,
            'Crossfeed Level: 4.5 dB',
          ),
        );
        expect(cutoffPill, findsOneWidget);
        expect(crossfeedPill, findsOneWidget);
        expect(
          tester.getTopLeft(crossfeedPill).dy,
          greaterThan(tester.getTopLeft(cutoffPill).dy + 20),
        );

        // Smart Silence Threshold is a CompactSliderControl pill instead of an inline Slider
        expect(
          find.descendant(of: silenceSubCard, matching: find.byType(Slider)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: silenceSubCard,
            matching: find.widgetWithText(
              CompactSliderControl,
              'Threshold: -45.0 dB',
            ),
          ),
          findsOneWidget,
        );

        // Stereo Widener uses the same DspSubCard layout with a Width CompactSliderControl pill
        expect(
          find.descendant(of: widenerSubCard, matching: find.byType(Slider)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: widenerSubCard,
            matching: find.widgetWithText(CompactSliderControl, 'Width: 1.00x'),
          ),
          findsOneWidget,
        );

        // Algorithmic Reverb mirrors BS2B: Preset dropdown + 5 vertical CompactSliderControl pills
        expect(
          find.descendant(of: reverbSubCard, matching: find.byType(Slider)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: reverbSubCard,
            matching: find.byWidgetPredicate(
              (w) => w is InputDecorator && w.decoration.labelText == 'Preset',
            ),
          ),
          findsOneWidget,
        );
        final roomSizePill = find.descendant(
          of: reverbSubCard,
          matching: find.widgetWithText(CompactSliderControl, 'Room Size: 0.50'),
        );
        final dampingPill = find.descendant(
          of: reverbSubCard,
          matching: find.widgetWithText(CompactSliderControl, 'Damping: 0.50'),
        );
        final reverbWidthPill = find.descendant(
          of: reverbSubCard,
          matching: find.widgetWithText(CompactSliderControl, 'Width: 1.00'),
        );
        final wetPill = find.descendant(
          of: reverbSubCard,
          matching: find.widgetWithText(
            CompactSliderControl,
            'Wet Level: 0.30x',
          ),
        );
        final dryPill = find.descendant(
          of: reverbSubCard,
          matching: find.widgetWithText(
            CompactSliderControl,
            'Dry Level: 1.00x',
          ),
        );
        expect(roomSizePill, findsOneWidget);
        expect(dampingPill, findsOneWidget);
        expect(reverbWidthPill, findsOneWidget);
        expect(wetPill, findsOneWidget);
        expect(dryPill, findsOneWidget);
        expect(
          tester.getTopLeft(dampingPill).dy,
          greaterThan(tester.getTopLeft(roomSizePill).dy + 20),
        );
        expect(
          tester.getTopLeft(reverbWidthPill).dy,
          greaterThan(tester.getTopLeft(dampingPill).dy + 20),
        );
        expect(
          tester.getTopLeft(wetPill).dy,
          greaterThan(tester.getTopLeft(reverbWidthPill).dy + 20),
        );
        expect(
          tester.getTopLeft(dryPill).dy,
          greaterThan(tester.getTopLeft(wetPill).dy + 20),
        );
      },
    );

    testWidgets(
      'Crossfeed pills and Preset dropdown stay disabled when OFF, close overlay when turned OFF, and switch Presets / Custom',
      (tester) async {
        await pumpDspCard(tester, size: const Size(800, 900));

        final crossfeedSubCard = subCardFor('Bauer BS2B Crossfeed');
        final cutoffPillFinder = find.descendant(
          of: crossfeedSubCard,
          matching: find.widgetWithText(
            CompactSliderControl,
            'Lowpass Cutoff: 700 Hz',
          ),
        );
        final crossfeedPillFinder = find.descendant(
          of: crossfeedSubCard,
          matching: find.widgetWithText(
            CompactSliderControl,
            'Crossfeed Level: 4.5 dB',
          ),
        );

        expect(
          tester.widget<CompactSliderControl>(cutoffPillFinder).disabled,
          isTrue,
        );
        expect(
          tester.widget<CompactSliderControl>(crossfeedPillFinder).disabled,
          isTrue,
        );

        // Baseline: No inline sliders exist in DspEffectsCard when all pills are closed.
        // Tapping disabled controls opens nothing.
        expect(find.byType(Slider), findsNothing);
        await tester.tap(cutoffPillFinder, warnIfMissed: false);
        await tester.pump();
        expect(find.byType(Slider), findsNothing);

        await tester.tap(find.text('Moffat-Bauer'), warnIfMissed: false);
        await tester.pump();
        expect(find.text('Chu Moy'), findsNothing);

        // Toggle Crossfeed ON via its Switch
        final crossfeedSwitch = find.descendant(
          of: crossfeedSubCard,
          matching: find.byType(Switch),
        );
        await tester.tap(crossfeedSwitch);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.descendant(of: crossfeedSubCard, matching: find.text('ON')),
          findsOneWidget,
        );
        expect(
          tester.widget<CompactSliderControl>(cutoffPillFinder).disabled,
          isFalse,
        );

        // Open Cutoff overlay -> disabling via controller closes it automatically
        await tester.tap(cutoffPillFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final cutoffOverlaySlider = find.byWidgetPredicate(
          (w) => w is Slider && w.min == 300.0 && w.max == 2000.0,
        );
        expect(cutoffOverlaySlider, findsOneWidget);

        await tester.runAsync(() => controller.toggleCrossfeed(false));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(cutoffOverlaySlider, findsNothing);

        // Re-enable and switch Preset -> Chu Moy, then drag Cutoff -> Custom
        await tester.tap(crossfeedSwitch);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        await tester.tap(find.text('Moffat-Bauer'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Chu Moy').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.crossfeed.cutoffHz, 700.0);
        expect(controller.crossfeed.feedDb, 6.0);
        expect(find.text('Crossfeed Level: 6.0 dB'), findsOneWidget);

        await tester.tap(cutoffPillFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.drag(cutoffOverlaySlider, const Offset(40, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(const Offset(5, 5));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(controller.crossfeed.cutoffHz, greaterThan(700.0));
        expect(find.text('Custom'), findsOneWidget);
      },
    );

    testWidgets(
      'Smart Silence Threshold pill stays disabled when OFF and updates threshold via overlay when ON',
      (tester) async {
        await pumpDspCard(tester, size: const Size(800, 900));

        final silenceSubCard = subCardFor('Smart Silence Skipping');
        final thresholdPillFinder = find.descendant(
          of: silenceSubCard,
          matching: find.widgetWithText(
            CompactSliderControl,
            'Threshold: -45.0 dB',
          ),
        );
        expect(
          tester.widget<CompactSliderControl>(thresholdPillFinder).disabled,
          isTrue,
        );

        final thresholdOverlaySlider = find.byWidgetPredicate(
          (w) => w is Slider && w.min == -90.0 && w.max == -20.0,
        );
        await tester.tap(thresholdPillFinder, warnIfMissed: false);
        await tester.pump();
        expect(thresholdOverlaySlider, findsNothing);

        final silenceSwitch = find.descendant(
          of: silenceSubCard,
          matching: find.byType(Switch),
        );
        await tester.tap(silenceSwitch);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          tester.widget<CompactSliderControl>(thresholdPillFinder).disabled,
          isFalse,
        );

        await tester.tap(thresholdPillFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(thresholdOverlaySlider, findsOneWidget);

        await tester.drag(thresholdOverlaySlider, const Offset(40, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(const Offset(5, 5));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(controller.silenceThresholdDb, greaterThan(-45.0));
      },
    );

    testWidgets(
      'Stereo Widener Width pill stays disabled when OFF and updates width via overlay when ON',
      (tester) async {
        await pumpDspCard(tester, size: const Size(800, 900));

        final widenerSubCard = subCardFor('Stereo Widener');
        final widthPillFinder = find.descendant(
          of: widenerSubCard,
          matching: find.widgetWithText(CompactSliderControl, 'Width: 1.00x'),
        );
        expect(
          tester.widget<CompactSliderControl>(widthPillFinder).disabled,
          isTrue,
        );

        final widthOverlaySlider = find.byWidgetPredicate(
          (w) => w is Slider && w.min == 0.0 && w.max == 2.0,
        );
        await tester.tap(widthPillFinder, warnIfMissed: false);
        await tester.pump();
        expect(widthOverlaySlider, findsNothing);

        final widenerSwitch = find.descendant(
          of: widenerSubCard,
          matching: find.byType(Switch),
        );
        await tester.tap(widenerSwitch);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.descendant(of: widenerSubCard, matching: find.text('ON')),
          findsOneWidget,
        );
        expect(
          tester.widget<CompactSliderControl>(widthPillFinder).disabled,
          isFalse,
        );

        await tester.tap(widthPillFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(widthOverlaySlider, findsOneWidget);

        await tester.drag(widthOverlaySlider, const Offset(40, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(const Offset(5, 5));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(controller.spatializerWidth, greaterThan(1.0));
      },
    );

    testWidgets(
      'Algorithmic Reverb Switch, Preset dropdown, Custom mode, and 5 vertical pills behave like Bauer BS2B',
      (tester) async {
        await pumpDspCard(tester, size: const Size(900, 900));

        final reverbSubCard = subCardFor('Algorithmic Reverb');
        final roomSizePill = find.descendant(
          of: reverbSubCard,
          matching: find.widgetWithText(CompactSliderControl, 'Room Size: 0.50'),
        );
        final reverbSwitch = find.descendant(
          of: reverbSubCard,
          matching: find.byType(Switch),
        );

        expect(
          tester.widget<CompactSliderControl>(roomSizePill).disabled,
          isTrue,
        );

        // Disabled while OFF
        final roomSizeOverlaySlider = find.byWidgetPredicate(
          (w) => w is Slider && w.min == 0.0 && w.max == 1.0,
        );
        await tester.tap(roomSizePill, warnIfMissed: false);
        await tester.pump();
        expect(roomSizeOverlaySlider, findsNothing);

        await tester.tap(find.text('Studio'), warnIfMissed: false);
        await tester.pump();
        expect(find.text('Concert Hall'), findsNothing);

        // Enable Reverb via Switch -> defaults to Studio and enables pills
        await tester.tap(reverbSwitch);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(controller.reverbEnabled, isTrue);
        expect(
          find.descendant(of: reverbSubCard, matching: find.text('ON')),
          findsOneWidget,
        );
        expect(
          tester.widget<CompactSliderControl>(roomSizePill).disabled,
          isFalse,
        );

        // Switch preset -> Concert Hall
        await tester.tap(find.text('Studio'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Concert Hall').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.reverbRoomSize, closeTo(0.80, 0.001));
        expect(controller.reverbWet, closeTo(0.40, 0.001));

        final concertRoomPill = find.descendant(
          of: reverbSubCard,
          matching: find.widgetWithText(CompactSliderControl, 'Room Size: 0.80'),
        );
        await tester.tap(concertRoomPill);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(roomSizeOverlaySlider, findsOneWidget);

        await tester.drag(roomSizeOverlaySlider, const Offset(-40, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(const Offset(5, 5));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(controller.reverbRoomSize, lessThan(0.80));
        expect(
          find.descendant(of: reverbSubCard, matching: find.text('Custom')),
          findsOneWidget,
        );

        // Open overlay then toggle OFF via controller closes overlay automatically
        await tester.tap(
          find
              .descendant(
                of: reverbSubCard,
                matching: find.byType(CompactSliderControl),
              )
              .first,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(roomSizeOverlaySlider, findsOneWidget);

        await tester.runAsync(() => controller.toggleReverb(false));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(roomSizeOverlaySlider, findsNothing);
        expect(controller.reverbEnabled, isFalse);
      },
    );

    testWidgets(
      'Adapts 1/4 -> 1/3 -> 1/2 (2x2) -> 1 column across wide, medium, and narrow viewports with Equalizer 1 or 2/3 and zero overflows',
      (tester) async {
        // 740px host (684px inner width -> 620 <= w < 780): Silence + BS2B + Widener 1/3 row,
        // Reverb (1/3) + Equalizer (2/3) share Row 2 with aligned seams
        await pumpDspCard(tester, size: const Size(740, 1000));
        final thirdSilenceRect = tester.getRect(
          subCardBoxFor('Smart Silence Skipping'),
        );
        final thirdCrossfeedRect = tester.getRect(
          subCardBoxFor('Bauer BS2B Crossfeed'),
        );
        final thirdWidenerRect = tester.getRect(
          subCardBoxFor('Stereo Widener'),
        );
        final droppedReverbRect = tester.getRect(
          subCardBoxFor('Algorithmic Reverb'),
        );
        final thirdEqRect = tester.getRect(
          subCardBoxFor('ISO 266 10-Band Equalizer'),
        );
        expect(thirdCrossfeedRect.top, closeTo(thirdSilenceRect.top, 0.5));
        expect(thirdWidenerRect.top, closeTo(thirdSilenceRect.top, 0.5));
        expect(thirdCrossfeedRect.width, closeTo(thirdSilenceRect.width, 1.5));
        expect(thirdWidenerRect.width, closeTo(thirdSilenceRect.width, 1.5));
        expect(
          droppedReverbRect.top,
          greaterThanOrEqualTo(thirdSilenceRect.bottom),
        );
        expect(droppedReverbRect.left, closeTo(thirdSilenceRect.left, 0.5));
        expect(droppedReverbRect.width, closeTo(thirdSilenceRect.width, 1.5));
        expect(thirdEqRect.top, closeTo(droppedReverbRect.top, 0.5));
        expect(thirdEqRect.left, closeTo(thirdCrossfeedRect.left, 0.5));
        expect(thirdEqRect.right, closeTo(thirdWidenerRect.right, 0.5));
        expect(thirdEqRect.height, closeTo(droppedReverbRect.height, 0.5));

        // 560px host (504px inner width -> 420 <= w < 620): 2x2 grid (1/2 each) + full-width Equalizer (1)
        await pumpDspCard(tester, size: const Size(560, 1100));
        final halfSilenceRect = tester.getRect(
          subCardBoxFor('Smart Silence Skipping'),
        );
        final halfCrossfeedRect = tester.getRect(
          subCardBoxFor('Bauer BS2B Crossfeed'),
        );
        final halfWidenerRect = tester.getRect(
          subCardBoxFor('Stereo Widener'),
        );
        final halfReverbRect = tester.getRect(
          subCardBoxFor('Algorithmic Reverb'),
        );
        final halfEqRect = tester.getRect(
          subCardBoxFor('ISO 266 10-Band Equalizer'),
        );
        expect(halfCrossfeedRect.top, closeTo(halfSilenceRect.top, 0.5));
        expect(halfCrossfeedRect.width, closeTo(halfSilenceRect.width, 1.0));
        expect(
          halfWidenerRect.top,
          greaterThanOrEqualTo(halfSilenceRect.bottom),
        );
        expect(halfReverbRect.top, closeTo(halfWidenerRect.top, 0.5));
        expect(halfReverbRect.width, closeTo(halfWidenerRect.width, 1.0));
        expect(halfEqRect.top, greaterThanOrEqualTo(halfReverbRect.bottom));
        expect(halfEqRect.left, closeTo(halfSilenceRect.left, 0.5));
        expect(halfEqRect.right, closeTo(halfCrossfeedRect.right, 0.5));

        // 480px card host (424px inner width = 960px desktop 2-col column width) also keeps 2x2 + full-width Equalizer
        await pumpDspCard(tester, size: const Size(480, 1100));
        final wideSilenceRect = tester.getRect(
          subCardBoxFor('Smart Silence Skipping'),
        );
        final wideCrossfeedRect = tester.getRect(
          subCardBoxFor('Bauer BS2B Crossfeed'),
        );
        final wideReverbRect = tester.getRect(
          subCardBoxFor('Algorithmic Reverb'),
        );
        final wideEqRect = tester.getRect(
          subCardBoxFor('ISO 266 10-Band Equalizer'),
        );
        expect(wideCrossfeedRect.top, closeTo(wideSilenceRect.top, 0.5));
        expect(wideCrossfeedRect.width, closeTo(wideSilenceRect.width, 1.0));
        expect(wideEqRect.top, greaterThanOrEqualTo(wideReverbRect.bottom));
        expect(wideEqRect.left, closeTo(wideSilenceRect.left, 0.5));
        expect(wideEqRect.right, closeTo(wideCrossfeedRect.right, 0.5));

        // 390px mobile (< 420 inner width): all 5 stack vertically 1 / 1 / 1 / 1 / 1
        await pumpDspCard(tester, size: const Size(390, 1200));
        final silenceRect = tester.getRect(
          subCardBoxFor('Smart Silence Skipping'),
        );
        final crossfeedRect = tester.getRect(
          subCardBoxFor('Bauer BS2B Crossfeed'),
        );
        final widenerRect = tester.getRect(subCardBoxFor('Stereo Widener'));
        final reverbRect = tester.getRect(subCardBoxFor('Algorithmic Reverb'));
        final eqRect = tester.getRect(
          subCardBoxFor('ISO 266 10-Band Equalizer'),
        );
        expect(crossfeedRect.top, greaterThanOrEqualTo(silenceRect.bottom));
        expect(widenerRect.top, greaterThanOrEqualTo(crossfeedRect.bottom));
        expect(reverbRect.top, greaterThanOrEqualTo(widenerRect.bottom));
        expect(eqRect.top, greaterThanOrEqualTo(reverbRect.bottom));

        await pumpDspCard(tester, size: const Size(280, 653), textScale: 1.5);
      },
    );

    testWidgets(
      'DspSubCard places icon, title, and switch in top row and description below',
      (tester) async {
        await pumpDspCard(tester, size: const Size(800, 900));

        final subCardBox = find.ancestor(
          of: find.text('Stereo Widener'),
          matching: find.byType(DspSubCard),
        );
        final iconRect = tester.getRect(
          find.descendant(
            of: subCardBox,
            matching: find.byIcon(Icons.surround_sound),
          ),
        );
        final titleRect = tester.getRect(
          find.descendant(
            of: subCardBox,
            matching: find.text('Stereo Widener'),
          ),
        );
        final switchRect = tester.getRect(
          find.descendant(
            of: subCardBox,
            matching: find.byType(Switch),
          ),
        );
        final subtitleRect = tester.getRect(
          find.descendant(
            of: subCardBox,
            matching: find.text('Inactive: standard Mid/Side spatializer field'),
          ),
        );

        expect(iconRect.right, lessThanOrEqualTo(titleRect.left + 1.0));
        expect(titleRect.right, lessThanOrEqualTo(switchRect.left + 1.0));
        expect((iconRect.center.dy - titleRect.center.dy).abs(), lessThan(8.0));
        expect(
          (switchRect.center.dy - titleRect.center.dy).abs(),
          lessThan(12.0),
        );
        expect(subtitleRect.top, greaterThanOrEqualTo(titleRect.bottom));
        expect(subtitleRect.left, lessThanOrEqualTo(iconRect.left + 2.0));

        // Limiter & Mono Downmix keep description directly beneath title (to the right of icon, left of switch)
        for (final entry in [
          (
            title: 'True-Peak Limiter',
            subtitle: controller.limiterEnabled
                ? 'Active: 0.0 dBFS ceiling'
                : 'Disabled / Bypass',
            icon: Icons.shield_outlined,
          ),
          (
            title: 'Mono Downmix',
            subtitle:
                controller.monoDownmix ? 'L+R downmixed' : 'Stereo discrete',
            icon: Icons.call_merge,
          ),
        ]) {
          final tileBox = find.ancestor(
            of: find.text(entry.title),
            matching: find.byType(Container),
          ).first;
          final tileIconRect = tester.getRect(
            find.descendant(of: tileBox, matching: find.byIcon(entry.icon)),
          );
          final tileTitleRect = tester.getRect(
            find.descendant(of: tileBox, matching: find.text(entry.title)),
          );
          final tileSubRect = tester.getRect(
            find.descendant(of: tileBox, matching: find.text(entry.subtitle)),
          );
          final tileSwitchRect = tester.getRect(
            find.descendant(of: tileBox, matching: find.byType(Switch)),
          );
          expect(tileSubRect.top, greaterThanOrEqualTo(tileTitleRect.bottom));
          expect(tileSubRect.left, closeTo(tileTitleRect.left, 0.5));
          expect(tileSubRect.left, greaterThanOrEqualTo(tileIconRect.right));
          expect(tileSubRect.right, lessThanOrEqualTo(tileSwitchRect.left + 1.0));
        }
      },
    );

    testWidgets(
      'CompactSliderControl overlay shows icon, slider, and live value text to the right',
      (tester) async {
        controller.setSpatializerEnabled(true);
        await pumpDspCard(tester, size: const Size(800, 900));

        await tester.ensureVisible(find.text('Width: 1.00x'));
        await tester.tap(find.text('Width: 1.00x'));
        await tester.pumpAndSettle();

        final resetBtnFinder = find.ancestor(
          of: find.byIcon(Icons.swap_horiz),
          matching: find.byType(IconButton),
        );
        expect(resetBtnFinder, findsOneWidget);
        final resetBtnRect = tester.getRect(resetBtnFinder);

        final overlayRowFinder = find.ancestor(
          of: resetBtnFinder,
          matching: find.byType(Row),
        );
        final sliderFinder = find.descendant(
          of: overlayRowFinder,
          matching: find.byType(Slider),
        );
        expect(sliderFinder, findsOneWidget);
        final sliderRect = tester.getRect(sliderFinder);
        expect(resetBtnRect.right, lessThanOrEqualTo(sliderRect.left + 2.0));

        final initialValFinder = find.descendant(
          of: overlayRowFinder,
          matching: find.text('1.00x'),
        );
        expect(initialValFinder, findsOneWidget);
        final initialValRect = tester.getRect(initialValFinder);
        expect(initialValRect.left, greaterThanOrEqualTo(sliderRect.right - 2.0));
        expect(
          (initialValRect.center.dy - sliderRect.center.dy).abs(),
          lessThan(8.0),
        );

        await tester.drag(sliderFinder, const Offset(40, 0));
        await tester.pump();

        expect(controller.spatializerWidth, greaterThan(1.0));
        final expectedValText = '${controller.spatializerWidth.toStringAsFixed(2)}x';
        final updatedValRect = tester.getRect(
          find.descendant(
            of: overlayRowFinder,
            matching: find.text(expectedValText),
          ),
        );
        expect(updatedValRect.left, greaterThanOrEqualTo(sliderRect.right - 2.0));
      },
    );

    testWidgets(
      'PlaybackEngineCard volume pill supports up to 200% and renders value in overlay',
      (tester) async {
        const size = Size(900, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: StudioTheme.darkTheme,
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: PlaybackEngineCard(controller: controller),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('Vol: 100%'));
        await tester.pumpAndSettle();

        final sliderFinder = find.byType(Slider);
        expect(sliderFinder, findsOneWidget);
        final sliderWidget = tester.widget<Slider>(sliderFinder);
        expect(sliderWidget.min, 0.0);
        expect(sliderWidget.max, 2.0);

        final sliderRect = tester.getRect(sliderFinder);
        final pctRect = tester.getRect(find.text('100%'));
        expect(pctRect.left, greaterThanOrEqualTo(sliderRect.right - 2.0));

        await tester.drag(sliderFinder, Offset(sliderRect.width, 0));
        await tester.pump();

        expect(controller.volume, closeTo(2.0, 0.02));
        expect(find.text('200%'), findsOneWidget);
        expect(find.text('Vol: 200%'), findsOneWidget);
      },
    );

    testWidgets(
      'EqualizerCard replaces badge with OFF/ON switch, removes preamp, and uses labeled Preset dropdown with Custom state',
      (tester) async {
        Future<void> pumpEq({
          Size size = const Size(640, 800),
          double textScale = 1.0,
        }) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          await tester.pumpWidget(
            MaterialApp(
              theme: StudioTheme.darkTheme,
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(textScale),
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: EqualizerCard(controller: controller),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
        }

        await pumpEq();

        expect(find.text('Acoustic RBJ Curves'), findsNothing);
        expect(find.byType(CompactSliderControl), findsNothing);
        expect(find.textContaining('Pre:'), findsNothing);
        expect(find.byType(ChoiceChip), findsNothing);

        final eqSwitchFinder = find.descendant(
          of: find.byType(EqualizerCard),
          matching: find.byType(Switch),
        );
        expect(eqSwitchFinder, findsOneWidget);
        expect(tester.widget<Switch>(eqSwitchFinder).value, isFalse);
        expect(find.text('OFF'), findsOneWidget);

        final presetInput = find.byWidgetPredicate(
          (w) => w is InputDecorator && w.decoration.labelText == 'Preset',
        );
        expect(presetInput, findsOneWidget);

        // Disabled dropdown ignores taps while OFF
        await tester.tap(find.text('Flat'), warnIfMissed: false);
        await tester.pump();
        expect(find.text('Rock'), findsNothing);

        // Toggle EQ ON via header Switch
        await tester.tap(eqSwitchFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.widget<Switch>(eqSwitchFinder).value, isTrue);
        expect(find.text('ON'), findsOneWidget);
        expect(controller.equalizerEnabled, isTrue);

        // Switch preset -> Rock via labeled dropdown
        await tester.tap(find.text('Flat'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Custom'), findsOneWidget);
        await tester.tap(find.text('Rock').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.selectedPreset, 'rock');
        expect(controller.currentEqualizer, Equalizer.rock);

        // Edit EQ curve via graph interaction -> automatically enters Custom preset
        final eqGraph = find.ancestor(
          of: find.byWidgetPredicate(
            (w) =>
                w is CustomPaint &&
                w.painter.runtimeType.toString() == 'EqCurvePainter',
          ),
          matching: find.byType(GestureDetector),
        );
        expect(eqGraph, findsOneWidget);
        final graphRect = tester.getRect(eqGraph);
        await tester.tapAt(
          Offset(graphRect.left + graphRect.width / 11.0, graphRect.top + 16),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.selectedPreset, 'custom');
        expect(find.text('Custom'), findsOneWidget);

        // Toggling OFF dims/disables while preserving Custom curve and preset
        await tester.tap(eqSwitchFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(controller.equalizerEnabled, isFalse);
        expect(controller.selectedPreset, 'custom');
        expect(find.text('OFF'), findsOneWidget);

        await pumpEq(size: const Size(280, 653), textScale: 1.5);
      },
    );

    testWidgets(
      'DSP compact row hosts 7 tiles (1/7 when wide) with >=215px min width including Pause on Device Change & Dynamic Metadata Event Stream',
      (tester) async {
        Finder headerTileFor(String title) => find
            .ancestor(
              of: find.text(title),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Container &&
                    w.decoration is BoxDecoration &&
                    (w.decoration! as BoxDecoration).color ==
                        const Color(0xFF0A0F1D),
              ),
            )
            .first;

        // Ultra-wide (1620px host -> 1564px inner width >= 1553): all 7 share 1 row at 1/7 each (>=215px wide)
        await pumpDspCard(tester, size: const Size(1620, 900));

        final rgTile = headerTileFor('ReplayGain Normalization');
        final limiterTile = headerTileFor('True-Peak Limiter');
        final monoTile = headerTileFor('Mono Downmix');
        final preampTile = headerTileFor('Preamp Gain');
        final balanceTile = headerTileFor('Stereo Balance');
        final pauseTile = headerTileFor('Pause on Device Change');
        final metadataTile = headerTileFor('Dynamic Metadata Event Stream');

        final rgRect = tester.getRect(rgTile);
        final limiterRect = tester.getRect(limiterTile);
        final monoRect = tester.getRect(monoTile);
        final preampRect = tester.getRect(preampTile);
        final balanceRect = tester.getRect(balanceTile);
        final pauseRect = tester.getRect(pauseTile);
        final metadataRect = tester.getRect(metadataTile);

        expect(limiterRect.top, closeTo(rgRect.top, 0.5));
        expect(monoRect.top, closeTo(rgRect.top, 0.5));
        expect(preampRect.top, closeTo(rgRect.top, 0.5));
        expect(balanceRect.top, closeTo(rgRect.top, 0.5));
        expect(pauseRect.top, closeTo(rgRect.top, 0.5));
        expect(metadataRect.top, closeTo(rgRect.top, 0.5));

        expect(rgRect.right, lessThanOrEqualTo(limiterRect.left));
        expect(limiterRect.right, lessThanOrEqualTo(monoRect.left));
        expect(monoRect.right, lessThanOrEqualTo(preampRect.left));
        expect(preampRect.right, lessThanOrEqualTo(balanceRect.left));
        expect(balanceRect.right, lessThanOrEqualTo(pauseRect.left));
        expect(pauseRect.right, lessThanOrEqualTo(metadataRect.left));

        for (final rect in [
          rgRect,
          limiterRect,
          monoRect,
          preampRect,
          balanceRect,
          pauseRect,
          metadataRect,
        ]) {
          expect(rect.width, greaterThanOrEqualTo(215.0));
          expect(rect.width, closeTo(rgRect.width, 1.5));
          expect(rect.height, closeTo(rgRect.height, 0.5));
        }

        // Verify Preamp & Stereo Balance tiles: [Icon, Title+Subtitle, Value-only pill (no pill icon/label)]
        final preampPill = find.descendant(
          of: preampTile,
          matching: find.byType(CompactSliderControl),
        );
        final balancePill = find.descendant(
          of: balanceTile,
          matching: find.byType(CompactSliderControl),
        );
        expect(preampPill, findsOneWidget);
        expect(balancePill, findsOneWidget);
        expect(
          tester.widget<CompactSliderControl>(preampPill).showTriggerIcon,
          isFalse,
        );
        expect(
          tester.widget<CompactSliderControl>(balancePill).showTriggerIcon,
          isFalse,
        );
        expect(
          find.descendant(of: preampPill, matching: find.byType(Icon)),
          findsNothing,
        );
        expect(
          find.descendant(of: balancePill, matching: find.byType(Icon)),
          findsNothing,
        );
        expect(
          find.descendant(of: preampPill, matching: find.text('+0.0 dB')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: balancePill, matching: find.text('Center')),
          findsOneWidget,
        );

        // Open Stereo Balance pill overlay, drag slider, and verify live update & pill text
        await tester.tap(balancePill);
        await tester.pumpAndSettle();
        final balanceSlider = find.byWidgetPredicate(
          (w) => w is Slider && w.min == -1.0 && w.max == 1.0,
        );
        expect(balanceSlider, findsOneWidget);
        await tester.drag(balanceSlider, const Offset(40, 0));
        await tester.pump();
        expect(controller.stereoBalance, greaterThan(0.0));
        expect(find.textContaining('R '), findsWidgets);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        // Verify Pause on Device Change & Dynamic Metadata Event Stream switches work inside DSP card
        final pauseSwitch = find.descendant(
          of: pauseTile,
          matching: find.byType(Switch),
        );
        final metadataSwitch = find.descendant(
          of: metadataTile,
          matching: find.byType(Switch),
        );
        expect(pauseSwitch, findsOneWidget);
        expect(metadataSwitch, findsOneWidget);
        final initialPause = controller.pauseOnDeviceChange;
        await tester.tap(pauseSwitch);
        await tester.pump();
        expect(controller.pauseOnDeviceChange, !initialPause);
        final initialMetadata = controller.metadataEnabled;
        await tester.tap(metadataSwitch);
        await tester.pump();
        expect(controller.metadataEnabled, !initialMetadata);

        // 960px host (904px inner width: 884..1106 -> 4 cols, not cramped 5): 4 on row 1, 3 on row 2
        await pumpDspCard(tester, size: const Size(960, 900));
        final fourRg = tester.getRect(headerTileFor('ReplayGain Normalization'));
        final fourPreamp = tester.getRect(headerTileFor('Preamp Gain'));
        final fourBalance = tester.getRect(headerTileFor('Stereo Balance'));
        final fourMetadata = tester.getRect(
          headerTileFor('Dynamic Metadata Event Stream'),
        );
        expect(fourPreamp.top, closeTo(fourRg.top, 0.5));
        expect(fourBalance.top, greaterThanOrEqualTo(fourRg.bottom));
        expect(fourMetadata.top, closeTo(fourBalance.top, 0.5));
        expect(fourRg.width, greaterThanOrEqualTo(215.0));

        // 800px host (744px inner width: 661..883 -> 3 columns): 3 on row 1, 3 on row 2, 1 on row 3
        await pumpDspCard(tester, size: const Size(800, 900));
        final threeRg = tester.getRect(headerTileFor('ReplayGain Normalization'));
        final threeLimiter = tester.getRect(headerTileFor('True-Peak Limiter'));
        final threeMono = tester.getRect(headerTileFor('Mono Downmix'));
        final threePreamp = tester.getRect(headerTileFor('Preamp Gain'));
        final threePause = tester.getRect(headerTileFor('Pause on Device Change'));
        final threeMetadata = tester.getRect(
          headerTileFor('Dynamic Metadata Event Stream'),
        );
        expect(threeLimiter.top, closeTo(threeRg.top, 0.5));
        expect(threeMono.top, closeTo(threeRg.top, 0.5));
        expect(threePreamp.top, greaterThanOrEqualTo(threeRg.bottom));
        expect(threePause.top, closeTo(threePreamp.top, 0.5));
        expect(threeMetadata.top, greaterThanOrEqualTo(threePreamp.bottom));
        expect(threeRg.width, greaterThanOrEqualTo(215.0));

        // Verify matching tile internals: Icon + [Title / Subtitle] + Output-style dropdown (no Switch)
        final rgIconRect = tester.getRect(
          find.descendant(of: rgTile, matching: find.byIcon(Icons.equalizer)),
        );
        final rgTitleRect = tester.getRect(
          find.descendant(
            of: rgTile,
            matching: find.text('ReplayGain Normalization'),
          ),
        );
        final rgSubRect = tester.getRect(
          find.descendant(
            of: rgTile,
            matching: find.text('Operating Mode: TRACK'),
          ),
        );
        expect(
          find.descendant(of: rgTile, matching: find.byType(Switch)),
          findsNothing,
        );

        final rgDropdown = find.descendant(
          of: rgTile,
          matching: find.byWidgetPredicate(
            (w) => w is DropdownButton<ReplayGainMode>,
          ),
        );
        expect(rgDropdown, findsOneWidget);
        final rgDropdownBox = find
            .ancestor(
              of: rgDropdown,
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Container &&
                    w.decoration is BoxDecoration &&
                    (w.decoration! as BoxDecoration).color ==
                        const Color(0xFF070B14),
              ),
            )
            .first;
        final rgDropdownRect = tester.getRect(rgDropdownBox);

        expect(rgSubRect.top, greaterThanOrEqualTo(rgTitleRect.bottom));
        expect(rgSubRect.left, closeTo(rgTitleRect.left, 0.5));
        expect(rgSubRect.left, greaterThanOrEqualTo(rgIconRect.right));
        expect(rgDropdownRect.left, greaterThanOrEqualTo(rgTitleRect.right - 1.0));

        // Select FORCED mode via styled dropdown
        await tester.tap(rgDropdown);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('FORCED').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.replayGainMode, ReplayGainMode.forced);
        expect(find.text('Operating Mode: FORCED'), findsOneWidget);

        // Medium (540px host -> 484px inner width >= 438 -> 2 columns >=215px): ReplayGain & Limiter row 1, Mono row 2
        await pumpDspCard(tester, size: const Size(540, 1000));
        final medLimiter = tester.getRect(headerTileFor('True-Peak Limiter'));
        final medMono = tester.getRect(headerTileFor('Mono Downmix'));
        final medRg = tester.getRect(headerTileFor('ReplayGain Normalization'));
        expect(medRg.top, closeTo(medLimiter.top, 0.5));
        expect(medRg.right, lessThanOrEqualTo(medLimiter.left));
        expect(medRg.width, greaterThanOrEqualTo(215.0));
        expect(medMono.top, greaterThanOrEqualTo(medLimiter.bottom));

        // 480px host (424px inner width < 438 -> 1 column rather than squeezing below 215px) & 390px mobile
        await pumpDspCard(tester, size: const Size(480, 1000));
        final narrowLimiter = tester.getRect(headerTileFor('True-Peak Limiter'));
        final narrowRg = tester.getRect(
          headerTileFor('ReplayGain Normalization'),
        );
        expect(narrowLimiter.top, greaterThanOrEqualTo(narrowRg.bottom));

        await pumpDspCard(tester, size: const Size(390, 1000));
        final mobLimiter = tester.getRect(headerTileFor('True-Peak Limiter'));
        final mobMono = tester.getRect(headerTileFor('Mono Downmix'));
        final mobRg = tester.getRect(headerTileFor('ReplayGain Normalization'));
        expect(mobLimiter.top, greaterThanOrEqualTo(mobRg.bottom));
        expect(mobMono.top, greaterThanOrEqualTo(mobLimiter.bottom));

        // Ultra-narrow 280x653 with 1.5x text scale renders with zero overflow
        await pumpDspCard(tester, size: const Size(280, 653), textScale: 1.5);
      },
    );
  });
}
