import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/app.dart';
import 'package:miniaudio_player_example/controllers/audio_engine_controller.dart';
import 'package:miniaudio_player_example/models/audio_track.dart';
import 'package:miniaudio_player_example/theme/studio_colors.dart';
import 'package:miniaudio_player_example/widgets/cards/playback_engine_card.dart';
import 'package:miniaudio_player_example/widgets/cards/playlist_queue_card.dart';
import 'package:miniaudio_player_example/widgets/cards/ram_sound_effects_card.dart';
import 'package:miniaudio_player_example/widgets/common/studio_badge.dart';
import 'package:miniaudio_player_example/widgets/common/studio_card.dart';
import 'package:miniaudio_player_example/widgets/painters/waveform_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Playback Track Selection & Dynamic Waveform Tests', () {
    test('AudioEngineController waveform defaults to sinusoidal and updates on new points', () {
      final controller = AudioEngineController();
      addTearDown(() {
        controller.dispose();
      });

      // Initially, controller.waveformPoints must be sinusoidal (length 72)
      final defaultWave = controller.waveformPoints;
      expect(defaultWave.length, equals(72));
      expect(defaultWave.every((val) => val >= 0.05 && val <= 1.0), isTrue);

      // Update waveform points (as from ReplayGain / Waveform analysis)
      final customPoints = List.generate(72, (i) => 0.2 + 0.5 * (i / 72.0));
      controller.updateWaveformPoints(customPoints);

      expect(controller.waveformPoints, equals(customPoints));

      // Reset to sinusoidal
      controller.resetWaveformToSinusoidal();
      expect(controller.waveformPoints.length, equals(72));
      expect(controller.waveformPoints, isNot(equals(customPoints)));
    });

    test('Cached waveform switching updates waveformPoints immediately for previously analyzed tracks', () async {
      final controller = AudioEngineController();
      addTearDown(() {
        controller.dispose();
      });

      final trackA = AudioTrack(
        id: 'track_a',
        title: 'Track A',
        artist: 'Artist A',
        source: AudioSource('/tmp/track_a.mp3'),
      );
      final trackB = AudioTrack(
        id: 'track_b',
        title: 'Track B',
        artist: 'Artist B',
        source: AudioSource('/tmp/track_b.mp3'),
      );

      final pointsA = List.generate(72, (i) => 0.1 + 0.2 * (i / 72.0));
      final pointsB = List.generate(72, (i) => 0.7 - 0.4 * (i / 72.0));

      // 1. First track analyzed & cached
      controller.updateWaveformPoints(pointsA, trackId: trackA.id);
      expect(controller.hasCachedWaveform('track_a'), isTrue);
      expect(controller.getCachedWaveform('track_a'), equals(pointsA));

      // 2. Second track analyzed & cached
      controller.updateWaveformPoints(pointsB, trackId: trackB.id);
      expect(controller.hasCachedWaveform('track_b'), isTrue);
      expect(controller.getCachedWaveform('track_b'), equals(pointsB));

      // 3. Select track A (now cached) -> waveformPoints must switch to pointsA
      await controller.selectTrack(trackA);
      expect(controller.waveformPoints, equals(pointsA));

      // 4. Select track B (now cached) -> waveformPoints must switch to pointsB
      await controller.selectTrack(trackB);
      expect(controller.waveformPoints, equals(pointsB));
    });

    testWidgets(
      'Queue drag handle uses left 6-dots and buildDefaultDragHandles is false',
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

        // Find ReorderableListView and verify buildDefaultDragHandles is false
        final reorderableFinder = find.byWidgetPredicate(
          (widget) =>
              widget is ReorderableListView && !widget.buildDefaultDragHandles,
        );
        expect(reorderableFinder, findsOneWidget);

        // Verify ReorderableDragStartListener is present around the leading 6 dots icon
        expect(find.byType(ReorderableDragStartListener), findsWidgets);
        expect(find.byIcon(Icons.drag_indicator), findsWidgets);
      },
    );

    testWidgets(
      'Waveform progress bar is rendered with non-zero size and is clickable',
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

        // Find the CustomPaint with WaveformPainter
        final customPaintFinder = find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is WaveformPainter,
        );
        expect(customPaintFinder, findsOneWidget);

        final box = tester.getRect(customPaintFinder);
        expect(box.width, greaterThan(100.0));
        expect(box.height, closeTo(42.0, 3.0));

        // Tap on the waveform (seeking)
        await tester.tapAt(
          Offset(box.left + box.width * 0.7, box.top + box.height / 2),
        );
        await tester.pump();

        // Drag across the waveform to seek smoothly
        await tester.drag(customPaintFinder, const Offset(30, 0));
        await tester.pump();
      },
    );

    testWidgets(
      'Tapping a track in playlist queue updates active track banner',
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

        // Scroll main page to make sure queue is visible
        final mainScrollable = find.byType(Scrollable).first;
        await tester.drag(mainScrollable, const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 100));

        final listTiles = find.descendant(
          of: find.byType(PlaylistQueueCard),
          matching: find.byType(ListTile),
        );
        expect(listTiles, findsWidgets);

        final secondTile = listTiles.at(1);
        await tester.ensureVisible(secondTile);
        await tester.pump(const Duration(milliseconds: 100));

        await tester.tap(secondTile);
        await tester.pump(const Duration(milliseconds: 100));

        final updatedSecondTile = find
            .descendant(
              of: find.byType(PlaylistQueueCard),
              matching: find.byType(ListTile),
            )
            .at(1);
        for (var attempt = 0; attempt < 30; attempt++) {
          await tester.runAsync(() async {
            await Future.delayed(const Duration(milliseconds: 100));
          });
          await tester.pump(const Duration(milliseconds: 100));
          final candidate =
              tester.widget<ListTile>(updatedSecondTile).title as Text;
          if (candidate.style?.color == StudioColors.accentCyan) {
            break;
          }
        }

        // Verify metadata button is removed from PlaylistQueueCard while queue index 1 is highlighted active
        expect(
          find.descendant(
            of: find.byType(PlaylistQueueCard),
            matching: find.byIcon(Icons.info_outline),
          ),
          findsNothing,
        );
        final secondTitleWidget =
            tester.widget<ListTile>(updatedSecondTile).title as Text;
        expect(secondTitleWidget.style?.color, equals(StudioColors.accentCyan));
        expect(secondTitleWidget.style?.fontWeight, equals(FontWeight.bold));
        final activeSecondTitle = secondTitleWidget.data!;

        // Scroll back up to the top to verify active track banner
        await tester.drag(mainScrollable, const Offset(0, 700));
        await tester.pump(const Duration(milliseconds: 100));

        // Verify active track banner inside PlaybackEngineCard displays the selected second track title
        // and keeps the single Inspect Metadata button in PlaybackEngineCard.
        final activeBannerTitle = find.descendant(
          of: find.byType(PlaybackEngineCard),
          matching: find.text(activeSecondTitle),
        );
        expect(activeBannerTitle, findsWidgets);
        expect(
          find.descendant(
            of: find.byType(PlaybackEngineCard),
            matching: find.byIcon(Icons.info_outline),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'PlaylistQueueCard places compact Curve dropdown, Auto/Manual, +, TRACKS badge, and Invert in one left-aligned Wrap row and removes queue metadata button',
      (tester) async {
        tester.view.physicalSize = const Size(900, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final controller = AudioEngineController();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 100));
          controller.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: PlaylistQueueCard(controller: controller),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);

        final queueCard = find.byType(PlaylistQueueCard);
        expect(queueCard, findsOneWidget);

        // No metadata inspect button in queue items
        expect(
          find.descendant(
            of: queueCard,
            matching: find.byIcon(Icons.info_outline),
          ),
          findsNothing,
        );
        // Replaced ChoiceChips with labeled compact DropdownButtonFormField<CrossfadeCurve>
        expect(
          find.descendant(of: queueCard, matching: find.byType(ChoiceChip)),
          findsNothing,
        );

        final curveDropdown = find.descendant(
          of: queueCard,
          matching: find.byWidgetPredicate(
            (w) => w is DropdownButtonFormField<CrossfadeCurve>,
          ),
        );
        expect(curveDropdown, findsOneWidget);
        expect(
          find.descendant(of: curveDropdown, matching: find.text('Curve')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: curveDropdown,
            matching: find.text('Equal Power'),
          ),
          findsOneWidget,
        );

        final autoPill = find.descendant(
          of: queueCard,
          matching: find.textContaining('Auto:'),
        );
        final manualPill = find.descendant(
          of: queueCard,
          matching: find.textContaining('Manual:'),
        );
        final addBtn = find.descendant(
          of: queueCard,
          matching: find.byIcon(Icons.add),
        );
        final tracksBadge = find.descendant(
          of: queueCard,
          matching: find.byWidgetPredicate(
            (w) => w is StudioBadge && w.label.contains('TRACKS'),
          ),
        );
        final invertBtn = find.descendant(
          of: queueCard,
          matching: find.byIcon(Icons.swap_vert),
        );

        // All 6 items share the same left-aligned Wrap
        final sharedWrap = find.ancestor(
          of: curveDropdown,
          matching: find.byWidgetPredicate(
            (w) => w is Wrap && w.alignment == WrapAlignment.start,
          ),
        );
        expect(sharedWrap, findsOneWidget);
        for (final item in [autoPill, manualPill, addBtn, tracksBadge, invertBtn]) {
          expect(
            find.descendant(of: sharedWrap, matching: item),
            findsOneWidget,
          );
          expect(
            tester.getCenter(item).dy,
            closeTo(tester.getCenter(curveDropdown).dy, 6.0),
          );
        }

        // Changing Curve dropdown to Linear updates controller.crossfadeConfig.curve
        await tester.tap(curveDropdown);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Linear').last);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.crossfadeConfig.curve, equals(CrossfadeCurve.linear));

        // Ultra-narrow 280px wraps cleanly without overflow
        tester.view.physicalSize = const Size(280, 900);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: PlaylistQueueCard(controller: controller),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'RamSoundEffectsCard uses Queue-like design with RAM badge, Reload, and Unload All in one Wrap row and icon+name list items',
      (tester) async {
        tester.view.physicalSize = const Size(900, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final controller = AudioEngineController();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 100));
          controller.dispose();
        });
        await tester.runAsync(() => controller.loadSampleEffects());

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: RamSoundEffectsCard(controller: controller),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);

        final effectsCard = find.byType(RamSoundEffectsCard);
        expect(effectsCard, findsOneWidget);

        // No trailing badge in StudioCard header (matches PlaylistQueueCard)
        final studioCard = tester.widget<StudioCard>(
          find.descendant(of: effectsCard, matching: find.byType(StudioCard)),
        );
        expect(studioCard.trailing, isNull);

        final ramBadge = find.descendant(
          of: effectsCard,
          matching: find.byWidgetPredicate(
            (w) => w is StudioBadge && w.label.contains('KB RAM'),
          ),
        );
        final reloadBtn = find.descendant(
          of: effectsCard,
          matching: find.text('Reload'),
        );
        final unloadAllBtn = find.descendant(
          of: effectsCard,
          matching: find.text('Unload All'),
        );

        final sharedWrap = find.ancestor(
          of: ramBadge,
          matching: find.byWidgetPredicate(
            (w) => w is Wrap && w.alignment == WrapAlignment.start,
          ),
        );
        expect(sharedWrap, findsOneWidget);
        for (final item in [ramBadge, reloadBtn, unloadAllBtn]) {
          expect(
            find.descendant(of: sharedWrap, matching: item),
            findsOneWidget,
          );
          expect(
            tester.getCenter(item).dy,
            closeTo(tester.getCenter(ramBadge).dy, 6.0),
          );
        }

        // Effect list shows only icon and name (no subtitle or trailing widgets)
        final effectTiles = find.descendant(
          of: effectsCard,
          matching: find.byType(ListTile),
        );
        expect(effectTiles, findsNWidgets(3));
        for (final expectedName in const [
          'Laser SFX (880Hz)',
          'Chime SFX (1320Hz)',
          'Beep SFX (440Hz)',
        ]) {
          expect(
            find.descendant(of: effectsCard, matching: find.text(expectedName)),
            findsOneWidget,
          );
        }
        for (var i = 0; i < 3; i++) {
          final tile = tester.widget<ListTile>(effectTiles.at(i));
          expect(tile.leading, isNotNull);
          expect(tile.title, isNotNull);
          expect(tile.subtitle, isNull);
          expect(tile.trailing, isNull);
        }

        // Unload All empties list and sets badge to 0.0 KB RAM; Reload restores effects
        await tester.tap(unloadAllBtn);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.descendant(of: effectsCard, matching: find.byType(ListTile)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: effectsCard,
            matching: find.byWidgetPredicate(
              (w) => w is StudioBadge && w.label == '0.0 KB RAM',
            ),
          ),
          findsOneWidget,
        );

        await tester.tap(reloadBtn);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.descendant(of: effectsCard, matching: find.byType(ListTile)),
          findsNWidgets(3),
        );

        // Ultra-narrow 280px wraps cleanly without overflow
        tester.view.physicalSize = const Size(280, 900);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: RamSoundEffectsCard(controller: controller),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
