import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/src/loader/custom_byte_provider.dart';
import 'package:miniaudio_player/src/platform/native/native_backend.dart';

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
  Future<Uint8List> readInitialBytes() async {
    return _fileBytes.sublist(0, min(8192, _fileBytes.length));
  }

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

  test('CustomDartByteSource asynchronous pull-with-prefetch bridge test', () async {
    final file = File('test/fixtures/tripartite/trailing_chunks.wav');
    expect(file.existsSync(), isTrue, reason: 'Test fixture wav file must exist');
    final bytes = await file.readAsBytes();

    final backend = NativePlayerBackend();
    backend.init(sampleRate: 44100, channels: 2, periodSize: 1024);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final provider = MockCustomByteProvider(bytes, streamId: 202);
    final bridge = DartByteProviderBridge(backend, provider);

    await bridge.start();

    // Verify initial probe opened successfully
    await backend.play();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Verify playback happened and custom requests were dispatched
    await backend.stop();
    bridge.dispose();
    await backend.dispose();

    expect(provider.requestedOffsets.isNotEmpty, isTrue,
        reason: 'Rust engine should have requested audio chunks from Dart provider');
  });
}
