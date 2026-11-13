import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/controllers/audio_engine_controller.dart';
import 'package:miniaudio_player_example/theme/studio_theme.dart';
import 'package:miniaudio_player_example/widgets/cards/dsp_effects_card.dart';
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
      'Places Smart Silence, Bauer BS2B Crossfeed & Stereo Widener 1/3 + 1/3 + 1/3 on wide width with shared DspSubCard design and pill controls',
      (tester) async {
        await pumpDspCard(tester, size: const Size(800, 900));

        expect(find.text('DYNAMIC DSP & SPATIAL MASTERING'), findsOneWidget);
        expect(find.text('Smart Silence Skipping'), findsOneWidget);
        expect(find.text('Bauer BS2B Crossfeed'), findsOneWidget);
        expect(find.text('Stereo Widener'), findsOneWidget);
        expect(find.byType(DspSubCard), findsNWidgets(3));
        expect(find.byType(ChoiceChip), findsNothing);
        expect(
          find.text('Left and Right audio channels are completely isolated'),
          findsNothing,
        );

        final silenceSubCard = subCardFor('Smart Silence Skipping');
        final crossfeedSubCard = subCardFor('Bauer BS2B Crossfeed');
        final widenerSubCard = subCardFor('Stereo Widener');
        expect(silenceSubCard, findsOneWidget);
        expect(crossfeedSubCard, findsOneWidget);
        expect(widenerSubCard, findsOneWidget);

        final silenceBox = tester.getRect(subCardBoxFor('Smart Silence Skipping'));
        final crossfeedBox = tester.getRect(subCardBoxFor('Bauer BS2B Crossfeed'));
        final widenerBox = tester.getRect(subCardBoxFor('Stereo Widener'));
        // All 3 sit in the same Row, each occupying ~1/3 width with matched height
        expect(crossfeedBox.top, closeTo(silenceBox.top, 0.5));
        expect(widenerBox.top, closeTo(silenceBox.top, 0.5));
        expect(crossfeedBox.left, greaterThan(silenceBox.right));
        expect(widenerBox.left, greaterThan(crossfeedBox.right));
        expect(crossfeedBox.width, closeTo(silenceBox.width, 1.0));
        expect(widenerBox.width, closeTo(silenceBox.width, 1.0));
        expect(crossfeedBox.height, closeTo(silenceBox.height, 0.5));
        expect(widenerBox.height, closeTo(silenceBox.height, 0.5));

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

        // Baseline: Preamp (-12..12) and Balance (-1..1) sliders exist in DspEffectsCard,
        // so an overlay slider would be the 3rd Slider. Tapping disabled controls opens nothing.
        expect(find.byType(Slider), findsNWidgets(2));
        await tester.tap(cutoffPillFinder, warnIfMissed: false);
        await tester.pump();
        expect(find.byType(Slider), findsNWidgets(2));

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
      'Adapts 1/3 -> 1/2 (with Widener below) -> 1 column across wide, medium, and narrow viewports with zero overflows',
      (tester) async {
        // 560px host (504px inner width -> 420 <= w < 620): Silence + BS2B 1/2 + 1/2, Widener drops below
        await pumpDspCard(tester, size: const Size(560, 900));
        final halfSilenceRect = tester.getRect(
          subCardBoxFor('Smart Silence Skipping'),
        );
        final halfCrossfeedRect = tester.getRect(
          subCardBoxFor('Bauer BS2B Crossfeed'),
        );
        final droppedWidenerRect = tester.getRect(
          subCardBoxFor('Stereo Widener'),
        );
        expect(halfCrossfeedRect.top, closeTo(halfSilenceRect.top, 0.5));
        expect(halfCrossfeedRect.width, closeTo(halfSilenceRect.width, 1.0));
        expect(
          droppedWidenerRect.top,
          greaterThanOrEqualTo(halfSilenceRect.bottom),
        );

        // 480px card host (424px inner width = 960px desktop 2-col column width) also keeps 1/2 + 1/2 cleanly
        await pumpDspCard(tester, size: const Size(480, 900));
        final wideSilenceRect = tester.getRect(
          subCardBoxFor('Smart Silence Skipping'),
        );
        final wideCrossfeedRect = tester.getRect(
          subCardBoxFor('Bauer BS2B Crossfeed'),
        );
        expect(wideCrossfeedRect.top, closeTo(wideSilenceRect.top, 0.5));
        expect(wideCrossfeedRect.width, closeTo(wideSilenceRect.width, 1.0));

        // 390px mobile (< 420 inner width): all 3 stack vertically 1 / 1 / 1
        await pumpDspCard(tester, size: const Size(390, 844));
        final silenceRect = tester.getRect(
          subCardBoxFor('Smart Silence Skipping'),
        );
        final crossfeedRect = tester.getRect(
          subCardBoxFor('Bauer BS2B Crossfeed'),
        );
        final widenerRect = tester.getRect(subCardBoxFor('Stereo Widener'));
        expect(crossfeedRect.top, greaterThanOrEqualTo(silenceRect.bottom));
        expect(widenerRect.top, greaterThanOrEqualTo(crossfeedRect.bottom));

        await pumpDspCard(tester, size: const Size(280, 653), textScale: 1.5);
      },
    );
  });
}
