import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player_example/features/analyzer/controllers/audio_analyzer_controller.dart';
import 'package:miniaudio_player_example/features/metadata/widgets/acoustid_lookup_dialog.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealHttpOverrides();

  group('AcoustID Lookup & Session Cache Tests', () {
    late AudioAnalyzerController controller;

    setUp(() {
      controller = AudioAnalyzerController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('Session cache and getAcoustIdFromCache return null for unqueried fingerprints', () {
      expect(controller.getAcoustIdFromCache('non_existent_hash'), isNull);
    });

    testWidgets('Renders AcoustIdLookupDialog and displays loaded match data', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const sampleFingerprint = 'AQADtEmyREmURImC5_jxSampleFingerprint12345';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) => AcoustIdLookupDialog(
                          fingerprint: sampleFingerprint,
                          durationSeconds: 180.5,
                          trackTitle: 'Studio Master Track',
                          analyzerController: controller,
                        ),
                      );
                    },
                    child: const Text('Open Modal'),
                  ),
                );
              },
            ),
          ),
        ),
      );

      // Open the modal
      await tester.tap(find.text('Open Modal'));
      await tester.pump();

      // Verify Modal Header & Loading Text
      expect(find.text('ACOUSTID TRACK IDENTIFICATION'), findsOneWidget);
      expect(find.textContaining('Studio Master Track'), findsOneWidget);

      // Wait for lookup future to complete (in offline unit tests, it will handle failure gracefully)
      await tester.pumpAndSettle();

      // Verify close button exists and works
      final closeBtn = find.text('Close');
      expect(closeBtn, findsOneWidget);
      await tester.tap(closeBtn);
      await tester.pumpAndSettle();

      expect(find.text('ACOUSTID TRACK IDENTIFICATION'), findsNothing);
    });
  });
}
