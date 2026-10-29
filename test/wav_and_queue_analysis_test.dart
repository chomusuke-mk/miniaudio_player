// ignore_for_file: avoid_print

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

void main() {
  test('User WAV file in /home/javier/Descargas/test opens fast with exact duration', () async {
    final wavFile = File('/home/javier/Descargas/test/SAD (FUNK)_22_1 (Copiar).wav');
    if (!wavFile.existsSync()) return;

    final player = MiniaudioPlayer();
    final sw = Stopwatch()..start();
    await player.action.open(AudioSource.file(wavFile.path));
    sw.stop();

    print('WAV open time: ${sw.elapsedMilliseconds} ms (duration=${player.state.duration})');
    expect(sw.elapsedMilliseconds, lessThan(100)); // Previously took 1,018 ms
    expect(player.state.duration.inSeconds, equals(82)); // Exactly 82.29s (not 43 minutes!)
    await player.dispose();
  });

  test('Benchmark opening opus files with 64KB probe', () async {
    final musicDir = Directory('/mnt/Last_Order/Música');
    if (!musicDir.existsSync()) return;
    final files = musicDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.opus'))
        .take(10)
        .toList();

    final player = MiniaudioPlayer();
    for (final f in files) {
      final sw = Stopwatch()..start();
      await player.action.open(AudioSource.file(f.path));
      sw.stop();
      print('${f.path.split("/").last} -> ${sw.elapsedMilliseconds} ms (dur=${player.state.duration})');
    }
    await player.dispose();
  });

  test('Queue of 1000 items from /mnt/Last_Order/Música and 400 consecutive next()', () async {
    final musicDir = Directory('/mnt/Last_Order/Música');
    if (!musicDir.existsSync()) return;
    final files = musicDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.opus'))
        .toList();

    expect(files.length, greaterThanOrEqualTo(1000));

    final items = [
      for (var i = 0; i < 1000; i++)
        EngineItem(
          source: AudioSource.file(files[i].path),
        ),
    ];

    final engine = MiniaudioEngine();
    await engine.action.open(items, startIndex: 0);
    await engine.action.play();

    expect(engine.state.currentIndex, 0);

    print('Starting 400 consecutive next() calls...');
    final sw = Stopwatch()..start();
    for (var i = 0; i < 400; i++) {
      await engine.action.next();
      if (engine.state.currentIndex != i + 1) {
        print('Mismatch at iteration $i: currentIndex is ${engine.state.currentIndex}, expected ${i + 1}');
        break;
      }
    }
    sw.stop();
    print('400 awaited next() took: ${sw.elapsedMilliseconds} ms (${sw.elapsedMilliseconds / 400} ms/op)');
    expect(engine.state.currentIndex, 400);

    await engine.dispose();
  });
}
