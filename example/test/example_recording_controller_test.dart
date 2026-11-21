import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player_example/controllers/audio_engine_controller.dart';
import 'package:miniaudio_player_example/widgets/cards/playback_engine_card.dart';
import 'package:open_file/open_file.dart';

void main() {
  test('AudioEngineController records valid PCM16 and Float32 WAV without package:file',
      () async {
    final controller = AudioEngineController();
    addTearDown(controller.dispose);

    // Record PCM16 via default OS temp directory helper
    controller.setRecordingFormat(AudioFileFormat.wav);
    controller.setRecordingSource(AudioOutputSource.all);

    await controller.startRecording();
    expect(controller.isRecording, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final pcmRes = await controller.stopRecording();
    addTearDown(() {
      final f = File(pcmRes.path);
      if (f.parent.existsSync()) {
        f.parent.deleteSync(recursive: true);
      }
    });

    expect(controller.isRecording, isFalse);
    expect(controller.lastRecordingResult, equals(pcmRes));
    expect(controller.lastRecordingError, isNull);
    expect(pcmRes.path.endsWith('.wav'), isTrue);
    expect(File(pcmRes.path).existsSync(), isTrue);

    final pcmBytes = File(pcmRes.path).readAsBytesSync();
    expect(pcmBytes.length, greaterThanOrEqualTo(44));
    expect(String.fromCharCodes(pcmBytes.sublist(0, 4)), equals('RIFF'));
    expect(ByteData.sublistView(pcmBytes).getUint16(20, Endian.little), equals(1));

    // Also verify Float32 recording flow
    controller.setRecordingFormat(AudioFileFormat.wavFloat32);
    await controller.startRecording();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final f32Res = await controller.stopRecording();
    addTearDown(() {
      final f = File(f32Res.path);
      if (f.parent.existsSync()) {
        f.parent.deleteSync(recursive: true);
      }
    });

    final f32Bytes = File(f32Res.path).readAsBytesSync();
    expect(f32Bytes.length, greaterThanOrEqualTo(44));
    expect(ByteData.sublistView(f32Bytes).getUint16(20, Endian.little), equals(3));
  });

  test('AudioEngineController useWebOpfs defaults to false and openLastRecording delegates to opener',
      () async {
    final openedCalls = <(String, String?)>[];
    final controller = AudioEngineController(
      fileOpener: (path, {type}) async {
        openedCalls.add((path, type));
        return OpenResult(type: ResultType.done, message: 'done');
      },
    );
    addTearDown(controller.dispose);

    expect(controller.useWebOpfs, isFalse);
    final beforeRec = await controller.openLastRecording();
    expect(beforeRec.type, equals(ResultType.fileNotFound));

    var recNotifications = 0;
    controller.recordingListenable.addListener(() => recNotifications++);
    controller.setUseWebOpfs(true);
    expect(controller.useWebOpfs, isTrue);
    expect(recNotifications, equals(1));

    await controller.startRecording();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final res = await controller.stopRecording();
    addTearDown(() {
      final f = File(res.path);
      if (f.parent.existsSync()) {
        f.parent.deleteSync(recursive: true);
      }
    });

    expect(controller.lastRecordingOpenTarget, equals(res.path));
    final openRes = await controller.openLastRecording();
    expect(openRes.type, equals(ResultType.done));
    expect(openedCalls, equals([(res.path, 'audio/wav')]));
  });

  testWidgets(
      'PlaybackEngineCard renders Web OPFS checkbox (unchecked by default + hover tooltip) and clickable Last recording',
      (tester) async {
    final openedPaths = <String>[];
    final downloadedCalls = <(String, String?)>[];
    var nextOpenResult = OpenResult(type: ResultType.done, message: 'done');
    final controller = AudioEngineController(
      fileOpener: (path, {type}) async {
        openedPaths.add(path);
        return nextOpenResult;
      },
      recordingDownloader: (res, {fileName}) async {
        downloadedCalls.add((res.path, fileName));
        return true;
      },
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlaybackEngineCard(
              controller: controller,
              showWebOptionsOverride: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('LIVE MEMORY RECORDER'), findsOneWidget);
    expect(find.text('Use OPFS'), findsOneWidget);

    final checkboxFinder = find.byType(Checkbox);
    expect(checkboxFinder, findsOneWidget);
    expect(tester.widget<Checkbox>(checkboxFinder).value, isFalse);

    final tooltipFinder = find.byWidgetPredicate(
      (w) =>
          w is Tooltip &&
          (w.message?.contains('large files') ?? false) &&
          (w.message?.contains('not available in all browsers') ?? false),
    );
    expect(tooltipFinder, findsOneWidget);

    await tester.tap(checkboxFinder);
    await tester.pump();
    expect(controller.useWebOpfs, isTrue);
    expect(tester.widget<Checkbox>(checkboxFinder).value, isTrue);
    expect(find.text('LIVE OPFS RECORDER'), findsOneWidget);

    await tester.runAsync(() async {
      await controller.startRecording();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final res = await controller.stopRecording();
      addTearDown(() {
        final f = File(res.path);
        if (f.parent.existsSync()) {
          f.parent.deleteSync(recursive: true);
        }
      });
    });
    await tester.pump();

    final lastFinder = find.textContaining('Last: studio_recording_');
    expect(lastFinder, findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.tap(lastFinder);
    await tester.pump();
    expect(openedPaths, equals([controller.lastRecordingResult!.path]));

    await tester.tap(find.text('Download'));
    await tester.pump();
    expect(
      downloadedCalls,
      equals([
        (controller.lastRecordingResult!.path, controller.lastRecordingFileName),
      ]),
    );
    expect(controller.lastRecordingFileName!.endsWith('.wav'), isTrue);

    await tester.runAsync(() async {
      await controller.playLastRecording();
    });
    await tester.pump();
    expect(
      controller.engine.state.queue
          .any((item) => item.uri == controller.lastRecordingResult!.path),
      isTrue,
    );
    await tester.runAsync(() async {
      await controller.engine.action.stop();
      await controller.engine.action.clearQueue();
    });

    nextOpenResult = OpenResult(
      type: ResultType.noAppToOpen,
      message: 'No WAV player found',
    );
    await tester.tap(lastFinder);
    await tester.pump();
    expect(find.textContaining('Could not open recording'), findsOneWidget);

    final recordedFilePath = controller.lastRecordingResult!.path;
    await tester.runAsync(() async {
      await controller.deleteLastRecording();
    });
    await tester.pump();
    expect(controller.lastRecordingResult, isNull);
    expect(File(recordedFilePath).existsSync(), isFalse);
  });

  test('AudioEngineController tracks extension and MIME type per recording format',
      () async {
    final openedCalls = <(String, String?)>[];
    final downloadedCalls = <(String, String?)>[];
    final controller = AudioEngineController(
      fileOpener: (path, {type}) async {
        openedCalls.add((path, type));
        return OpenResult(type: ResultType.done, message: 'done');
      },
      recordingDownloader: (res, {fileName}) async {
        downloadedCalls.add((res.path, fileName));
        return true;
      },
    );
    addTearDown(controller.dispose);

    controller.setRecordingFormat(AudioFileFormat.wavPack);
    await controller.startRecording();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    final wvRes = await controller.stopRecording();
    addTearDown(() {
      final f = File(wvRes.path);
      if (f.parent.existsSync()) {
        f.parent.deleteSync(recursive: true);
      }
    });

    expect(wvRes.path.endsWith('.wv'), isTrue);
    expect(controller.lastRecordingFileName?.endsWith('.wv'), isTrue);
    expect(File(wvRes.path).readAsBytesSync().sublist(0, 4), equals([0x77, 0x76, 0x70, 0x6B]));

    // Changing dropdown after stopping must keep opening/downloading the last recorded file with its MIME & name.
    controller.setRecordingFormat(AudioFileFormat.cafFloat32);
    final openRes = await controller.openLastRecording();
    expect(openRes.type, equals(ResultType.done));
    expect(openedCalls, equals([(wvRes.path, 'audio/x-wavpack')]));

    expect(await controller.downloadLastRecording(), isTrue);
    expect(
      downloadedCalls,
      equals([(wvRes.path, controller.lastRecordingFileName)]),
    );
  });
}
