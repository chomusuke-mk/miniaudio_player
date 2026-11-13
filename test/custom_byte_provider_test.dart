import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/concurrency_test_utils.dart';

class MockCustomByteProvider implements CustomByteProvider {
  final Uint8List _fileBytes;
  @override
  final int streamId;
  final List<int> requestedOffsets = [];

  MockCustomByteProvider(this._fileBytes, {this.streamId = 101});

  @override
  int? get totalBytes => _fileBytes.length;

  @override
  bool get isSeekable => true;

  @override
  Future<Uint8List> readBytes(int offset, int length) async {
    requestedOffsets.add(offset);
    if (offset >= _fileBytes.length) return Uint8List(0);
    final end = min(offset + length, _fileBytes.length);
    return _fileBytes.sublist(offset, end);
  }

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  test('CustomDartByteSource asynchronous pull-with-prefetch bridge test',
      () async {
    final file = File('test/fixtures/tripartite/trailing_chunks.wav');
    expect(file.existsSync(), isTrue,
        reason: 'Test fixture wav file must exist');
    final bytes = await file.readAsBytes();

    final player = MiniaudioPlayer();
    final provider = MockCustomByteProvider(bytes, streamId: 202);
    final source = AudioSource(provider);

    await player.action.setQueue([source]);

    await player.action.play();
    await waitForAudioProgress(
      player,
      minDelta: const Duration(milliseconds: 50),
    );

    await player.action.stop();
    await player.dispose();

    expect(provider.requestedOffsets.isNotEmpty, isTrue,
        reason:
            'Rust engine should have requested audio chunks from Dart provider');
  });
}
