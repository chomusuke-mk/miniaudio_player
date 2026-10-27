import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player_example/app.dart';
import 'package:miniaudio_player_example/controllers/audio_engine_controller.dart';
import 'package:miniaudio_player_example/widgets/cards/playback_engine_card.dart';
import 'package:miniaudio_player_example/widgets/cards/playlist_queue_card.dart';
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

    testWidgets('Queue drag handle uses left 6-dots and buildDefaultDragHandles is false', (tester) async {
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      await tester.pumpWidget(const MiniaudioPlayerExampleApp());
      await tester.pump();

      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      // Find ReorderableListView and verify buildDefaultDragHandles is false
      final reorderableFinder = find.byWidgetPredicate(
        (widget) => widget is ReorderableListView && !widget.buildDefaultDragHandles,
      );
      expect(reorderableFinder, findsOneWidget);

      // Verify ReorderableDragStartListener is present around the leading 6 dots icon
      expect(find.byType(ReorderableDragStartListener), findsWidgets);
      expect(find.byIcon(Icons.drag_indicator), findsWidgets);
    });

    testWidgets('Waveform progress bar is rendered with non-zero size and is clickable', (tester) async {
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      await tester.pumpWidget(const MiniaudioPlayerExampleApp());
      await tester.pump();

      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      // Find the CustomPaint with WaveformPainter
      final customPaintFinder = find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is WaveformPainter,
      );
      expect(customPaintFinder, findsOneWidget);

      final box = tester.getRect(customPaintFinder);
      expect(box.width, greaterThan(100.0));
      expect(box.height, closeTo(42.0, 3.0));

      // Tap on the waveform (seeking)
      await tester.tapAt(Offset(box.left + box.width * 0.7, box.top + box.height / 2));
      await tester.pump();

      // Drag across the waveform to seek smoothly
      await tester.drag(customPaintFinder, const Offset(30, 0));
      await tester.pump();
    });

    testWidgets('Tapping a track in playlist queue updates active track banner', (tester) async {
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      await tester.pumpWidget(const MiniaudioPlayerExampleApp());
      await tester.pump();

      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      // Scroll main page to make sure queue is visible
      final mainScrollable = find.byType(Scrollable).first;
      await tester.drag(mainScrollable, const Offset(0, -500));
      await tester.pumpAndSettle();

      final listTiles = find.descendant(
        of: find.byType(PlaylistQueueCard),
        matching: find.byType(ListTile),
      );
      expect(listTiles, findsWidgets);

      final secondTile = listTiles.at(1);
      await tester.ensureVisible(secondTile);
      await tester.pumpAndSettle();

      final titleFinder = find.descendant(of: secondTile, matching: find.byType(Text)).first;
      final secondTitle = (tester.widget(titleFinder) as Text).data!;

      await tester.tap(secondTile);
      await tester.pump();

      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump();

      // Scroll back up to the top to verify active track banner
      await tester.drag(mainScrollable, const Offset(0, 700));
      await tester.pumpAndSettle();

      // Verify active track banner inside PlaybackEngineCard displays second track title
      final activeBannerTitle = find.descendant(
        of: find.byType(PlaybackEngineCard),
        matching: find.text(secondTitle),
      );
      expect(activeBannerTitle, findsWidgets);
    });
  });
}
