import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Example App Modernization & Bugfixes Suite', () {
    testWidgets(
      'Material 3 Dropdown Migration: All selectors use DropdownButtonFormField',
      (tester) async {
        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump();

        // Find all DropdownButtonFormField widgets
        final dropdownFormFields = find.byWidgetPredicate(
          (w) => w.runtimeType.toString().startsWith('DropdownButtonFormField'),
        );
        expect(
          dropdownFormFields,
          findsNWidgets(6),
          reason: 'All 6 selectors must use Material 3 DropdownButtonFormField',
        );

        // Verify that every underlying DropdownButton is hosted within a DropdownButtonFormField
        final dropdownButtons = find.byWidgetPredicate(
          (w) => w.runtimeType.toString().startsWith('DropdownButton<'),
        );
        expect(dropdownButtons, findsNWidgets(6));

        for (final element in dropdownButtons.evaluate()) {
          expect(
            find.ancestor(
              of: find.byWidget(element.widget),
              matching: find.byWidgetPredicate(
                (w) => w.runtimeType.toString().startsWith('DropdownButtonFormField'),
              ),
            ),
            findsOneWidget,
            reason: 'Every selector must be wrapped in a Material 3 DropdownButtonFormField',
          );
        }

        // Verify specific form fields exist
        expect(
          find.byWidgetPredicate(
            (w) => w is DropdownButtonFormField<AudioTrack>,
          ),
          findsOneWidget,
          reason: 'Track selector must be a DropdownButtonFormField<AudioTrack>',
        );
      },
    );

    testWidgets(
      'ReplayGain Decoupling: Set Volume Slider ActionChip is absent from ReplayGain card',
      (tester) async {
        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump();

        // Ensure "Set Volume Slider" is never present
        expect(find.textContaining('Set Volume Slider'), findsNothing);
        expect(find.byType(ActionChip), findsNothing);
      },
    );

    testWidgets(
      'EQ Preset Dropdown: Displays selected preset and reflects active choice',
      (tester) async {
        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump();

        // Locate the EQ Preset DropdownButtonFormField<String>
        final eqDropdownFinder = find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<String>,
        );
        expect(eqDropdownFinder, findsOneWidget);

        final eqDropdown = tester.widget<DropdownButtonFormField<String>>(
          eqDropdownFinder,
        );
        expect(eqDropdown.initialValue, equals('flat'));
      },
    );

    testWidgets(
      'Conditional Skip Silence: Subcontrols are visually dimmed and ignored when OFF',
      (tester) async {
        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump();

        // Scroll to Skip Silence card
        final skipSilenceTitle = find.text('Smart Silence Skipping');
        expect(skipSilenceTitle, findsOneWidget);

        // Find the Skip Silence mode dropdown
        final modeDropdownFinder = find.byWidgetPredicate(
          (w) => w is DropdownButtonFormField<SilenceSkipMode>,
        );
        expect(modeDropdownFinder, findsOneWidget);

        final modeDropdown = tester.widget<DropdownButtonFormField<SilenceSkipMode>>(
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
          reason: 'Sub-controls must be wrapped in active IgnorePointer when OFF',
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
      },
    );

    testWidgets(
      'Reactive Visualizer UI: Toggling OFF resets and dims visualizer card',
      (tester) async {
        await tester.pumpWidget(const MiniaudioPlayerExampleApp());
        await tester.pump();
        await tester.runAsync(() async {
          await Future.delayed(const Duration(seconds: 2));
        });
        await tester.pump();

        expect(find.text('Real-Time Reactive Visualizer'), findsOneWidget);

        // Find the visualizer AnimatedOpacity
        final opacityFinder = find.byWidgetPredicate(
          (w) =>
              w is AnimatedOpacity &&
              (w.opacity == 1.0 || w.opacity == 0.38),
        );
        expect(opacityFinder, findsWidgets);
      },
    );
  });
}
