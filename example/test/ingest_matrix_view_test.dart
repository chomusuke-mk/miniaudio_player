import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player_example/core/theme/studio_theme.dart';
import 'package:miniaudio_player_example/features/ingest/views/ingest_matrix_view.dart';

void main() {
  group('IngestMatrixView v4.0.0 Architecture & Responsive Tests', () {
    const viewports = <String, ({Size size, double textScale})>{
      'desktop 1440x900': (size: Size(1440, 900), textScale: 1.0),
      'mobile 412x915': (size: Size(412, 915), textScale: 1.0),
      'narrow 280x653 @ 1.5x': (size: Size(280, 653), textScale: 1.5),
    };

    for (final entry in viewports.entries) {
      testWidgets(
        'renders updated Rust ingest & StreamSession pipeline cleanly on ${entry.key}',
        (tester) async {
          final errors = <FlutterErrorDetails>[];
          final originalOnError = FlutterError.onError;
          FlutterError.onError = (details) {
            errors.add(details);
          };
          addTearDown(() {
            FlutterError.onError = originalOnError;
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          tester.view.physicalSize = entry.value.size;
          tester.view.devicePixelRatio = 1.0;

          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: StudioTheme.darkTheme,
                home: MediaQuery(
                  data: MediaQueryData(
                    size: entry.value.size,
                    textScaler: TextScaler.linear(entry.value.textScale),
                  ),
                  child: const Scaffold(
                    body: SingleChildScrollView(
                      padding: EdgeInsets.all(16),
                      child: IngestMatrixView(),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
          } finally {
            FlutterError.onError = originalOnError;
          }

          expect(find.text('BYTESOURCE ROUTING & IO WORKER POOL'), findsOneWidget);
          expect(find.text('3-PLANE STREAMSESSION & DEMUX BRIDGE'), findsOneWidget);
          expect(find.text('3-PHASE SLIDING-WINDOW COALESCING'), findsOneWidget);
          expect(
            find.text('DOWNSTREAM DECODE -> DSP -> 5-BUS SPSC MATRIX'),
            findsOneWidget,
          );

          // Confirm obsolete C-era labels are absent
          expect(find.textContaining('UriCapabilityResolver'), findsNothing);
          expect(find.textContaining('map_buffer_t'), findsNothing);
          expect(find.textContaining('assetLoader'), findsNothing);

          expect(
            errors,
            isEmpty,
            reason:
                'IngestMatrixView threw FlutterError on ${entry.key}: ${errors.map((e) => e.exceptionAsString()).join('\n')}',
          );
        },
      );
    }
  });
}
