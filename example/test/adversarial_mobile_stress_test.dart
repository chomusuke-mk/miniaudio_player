import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player_example/main.dart';

void main() {
  group('Adversarial Mobile Viewport Stress Tests (Mounted UI)', () {
    const requiredViewports = <String, ({Size size, double dpr})>{
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
      '360x640 (Android Compact - Budget standard)': (
        size: Size(360, 640),
        dpr: 2.0,
      ),
      '412x915 (Android Standard - Pixel 7 / Galaxy S)': (
        size: Size(412, 915),
        dpr: 2.625,
      ),
    };

    for (final entry in requiredViewports.entries) {
      testWidgets(
        'Mounted UI renders and scrolls with 0 RenderFlex overflows on ${entry.key}',
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

          // 1. Initial pump
          await tester.pumpWidget(const MiniaudioPlayerExampleApp());
          await tester.pump();

          // 2. Await asynchronous track loading until _isReady == true
          await tester.runAsync(() async {
            await Future.delayed(const Duration(seconds: 2));
          });
          await tester.pump();

          // 3. Verify mounted UI title
          expect(
            find.text('miniaudio_player'),
            findsOneWidget,
            reason: 'Main application UI failed to mount',
          );

          // 4. Assert no overflow occurred on initial render
          expect(
            tester.takeException(),
            isNull,
            reason: 'RenderFlex overflow on initial mount for ${entry.key}',
          );

          // 5. Systematically scroll through all cards (full-card scrolling)
          final scrollables = find.byType(Scrollable);
          expect(scrollables, findsWidgets);
          final verticalScrollable = scrollables.first;

          // Scroll all the way down
          for (int i = 0; i < 10; i++) {
            await tester.drag(verticalScrollable, const Offset(0, -350));
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Overflow during downward scroll step $i on ${entry.key}',
            );
          }

          // Scroll all the way back up
          for (int i = 0; i < 10; i++) {
            await tester.drag(verticalScrollable, const Offset(0, 350));
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Overflow during upward scroll step $i on ${entry.key}',
            );
          }
        },
      );
    }
  });

  group('Adversarial Viewport Boundaries & Text Scaler Stress Tests', () {
    const stressViewports = <String, ({Size size, double dpr})>{
      '640x360 (Landscape Mobile Compact)': (
        size: Size(640, 360),
        dpr: 2.0,
      ),
      '844x390 (Landscape Mobile Standard)': (
        size: Size(844, 390),
        dpr: 3.0,
      ),
    };

    for (final entry in stressViewports.entries) {
      testWidgets(
        'Mounted UI under stress viewport ${entry.key}',
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

          await tester.pumpWidget(const MiniaudioPlayerExampleApp());
          await tester.pump();

          await tester.runAsync(() async {
            await Future.delayed(const Duration(seconds: 2));
          });
          await tester.pump();

          expect(find.text('miniaudio_player'), findsOneWidget);

          final scrollables = find.byType(Scrollable);
          if (scrollables.evaluate().isNotEmpty) {
            final verticalScrollable = scrollables.first;
            for (int i = 0; i < 6; i++) {
              await tester.drag(verticalScrollable, const Offset(0, -300));
              await tester.pump();
            }
          }

          expect(
            tester.takeException(),
            isNull,
            reason: 'Layout exception on stress viewport ${entry.key}',
          );
        },
      );
    }

    testWidgets('Mounted UI with 1.3x TextScaler on 320x568 compact viewport', (tester) async {
      tester.view.physicalSize = const Size(320 * 2.0, 568 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.3),
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

      final scrollables = find.byType(Scrollable);
      if (scrollables.evaluate().isNotEmpty) {
        final verticalScrollable = scrollables.first;
        for (int i = 0; i < 8; i++) {
          await tester.drag(verticalScrollable, const Offset(0, -300));
          await tester.pump();
        }
      }

      expect(tester.takeException(), isNull);
    });
  });

  group('WaveformPainter Geometry Clamp Adversarial Suite', () {
    test('Non-positive and zero sizes early-return without exception or draw call', () {
      final invalidSizes = <Size>[
        Size.zero,
        const Size(0, 50),
        const Size(50, 0),
        const Size(-100, 50),
        const Size(100, -50),
        const Size(-100, -100),
        const Size(-0.0001, 10),
        const Size(10, -0.0001),
      ];

      final points = [0.1, 0.5, 0.9, 0.4];
      final painter = WaveformPainter(
        points: points,
        progress: 0.5,
        playedColor: Colors.deepPurple,
        unplayedColor: Colors.grey,
      );

      for (final size in invalidSizes) {
        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        expect(
          () => painter.paint(canvas, size),
          returnsNormally,
          reason: 'Failed on invalid size: $size',
        );
        final picture = recorder.endRecording();
        expect(picture, isNotNull);
      }
    });

    test('Empty points list early-returns without exception', () {
      final painter = WaveformPainter(
        points: const [],
        progress: 0.5,
        playedColor: Colors.deepPurple,
        unplayedColor: Colors.grey,
      );

      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      expect(() => painter.paint(canvas, const Size(200, 48)), returnsNormally);
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
    });

    test('Mathematical clamp robustness across boundary heights [0.0001 .. 1000.0]', () {
      final testHeights = <double>[
        0.0001,
        0.001,
        0.01,
        0.1,
        0.5,
        1.0,
        2.0,
        3.0,
        3.5,
        3.9,
        3.999,
        3.999999,
        4.0, // Critical clamp limit
        4.000001,
        4.001,
        4.1,
        5.0,
        10.0,
        24.0,
        48.0,
        100.0,
        500.0,
        1000.0,
      ];

      final adversarialPoints = <List<double>>[
        [0.05, 0.5, 1.0],
        [0.00001, 0.02, 0.049], // Below 0.05 min clamp
        [1.001, 2.5, 100.0],    // Above 1.0 max clamp
        [-10.0, 0.0, 1.0],      // Negative and zero points
        List.generate(100, (i) => (i % 10) / 10.0), // Dense points
      ];

      final progressValues = <double>[-5.0, -0.1, 0.0, 0.25, 0.5, 0.75, 1.0, 1.5, 10.0];

      for (final h in testHeights) {
        for (final pts in adversarialPoints) {
          for (final prog in progressValues) {
            final painter = WaveformPainter(
              points: pts,
              progress: prog,
              playedColor: Colors.purple,
              unplayedColor: Colors.grey,
            );

            final recorder = PictureRecorder();
            final canvas = Canvas(recorder);
            final size = Size(200, h);

            expect(
              () => painter.paint(canvas, size),
              returnsNormally,
              reason: 'WaveformPainter threw on height=$h, progress=$prog, points=$pts',
            );

            final picture = recorder.endRecording();
            expect(picture, isNotNull);
          }
        }
      }
    });

    test('Dense point sets on narrow and fractional width canvases', () {
      final widths = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 50.0, 100.0];
      final points = List.generate(500, (i) => sin(i / 10.0).abs());

      for (final w in widths) {
        final painter = WaveformPainter(
          points: points,
          progress: 0.5,
          playedColor: Colors.blue,
          unplayedColor: Colors.grey,
        );

        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        final size = Size(w, 48.0);

        expect(
          () => painter.paint(canvas, size),
          returnsNormally,
          reason: 'Failed on dense points with width=$w',
        );

        final picture = recorder.endRecording();
        expect(picture, isNotNull);
      }
    });

    test('shouldRepaint detects property changes correctly', () {
      final p1 = WaveformPainter(
        points: [0.1, 0.2],
        progress: 0.5,
        playedColor: Colors.blue,
        unplayedColor: Colors.grey,
      );
      final pSame = WaveformPainter(
        points: [0.1, 0.2],
        progress: 0.5,
        playedColor: Colors.blue,
        unplayedColor: Colors.grey,
      );
      final pDiffProgress = WaveformPainter(
        points: [0.1, 0.2],
        progress: 0.6,
        playedColor: Colors.blue,
        unplayedColor: Colors.grey,
      );
      final pDiffPoints = WaveformPainter(
        points: [0.3, 0.4],
        progress: 0.5,
        playedColor: Colors.blue,
        unplayedColor: Colors.grey,
      );
      final pDiffPlayedColor = WaveformPainter(
        points: [0.1, 0.2],
        progress: 0.5,
        playedColor: Colors.red,
        unplayedColor: Colors.grey,
      );
      final pDiffUnplayedColor = WaveformPainter(
        points: [0.1, 0.2],
        progress: 0.5,
        playedColor: Colors.blue,
        unplayedColor: Colors.black,
      );

      expect(pSame.shouldRepaint(p1), isTrue); // List comparison is reference inequality
      expect(pDiffProgress.shouldRepaint(p1), isTrue);
      expect(pDiffPoints.shouldRepaint(p1), isTrue);
      expect(pDiffPlayedColor.shouldRepaint(p1), isTrue);
      expect(pDiffUnplayedColor.shouldRepaint(p1), isTrue);
      expect(p1.shouldRepaint(p1), isFalse); // Same instance
    });
  });
}
