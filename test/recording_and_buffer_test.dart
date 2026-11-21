import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/resolver/source_resolver_common.dart'
    show sanitizeOpfsRecordingPath;

Uint8List _generateWavSine({
  int sampleRate = 48000,
  int channels = 2,
  double durationSeconds = 1.5,
  double frequencyHz = 440.0,
  double amplitude = 0.5,
}) {
  final frameCount = (sampleRate * durationSeconds).round();
  final dataBytes = frameCount * channels * 2;
  final totalBytes = 44 + dataBytes;
  final bytes = Uint8List(totalBytes);
  final bd = ByteData.sublistView(bytes);

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes[offset + i] = s.codeUnitAt(i);
    }
  }

  writeAscii(0, 'RIFF');
  bd.setUint32(4, totalBytes - 8, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * channels * 2, Endian.little);
  bd.setUint16(32, channels * 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bd.setUint32(40, dataBytes, Endian.little);

  for (var f = 0; f < frameCount; f++) {
    final s = math.sin(2.0 * math.pi * frequencyHz * (f / sampleRate)) * amplitude;
    final sample = (s.clamp(-1.0, 1.0) * 32767.0).round();
    for (var ch = 0; ch < channels; ch++) {
      bd.setInt16(44 + (f * channels + ch) * 2, sample, Endian.little);
    }
  }
  return bytes;
}

final class _DelayedAsyncBuffer implements RecordingByteBuffer {
  final MemoryRecordingBuffer _inner = MemoryRecordingBuffer(path: 'async://mem.wav');
  final int failAfterWrites;
  int _writeCount = 0;

  _DelayedAsyncBuffer({this.failAfterWrites = 0});

  @override
  String? get path => _inner.path;

  @override
  int get lengthInBytes => _inner.lengthInBytes;

  @override
  Future<void> write(Uint8List bytes) async {
    _writeCount++;
    if (failAfterWrites > 0 && _writeCount >= failAfterWrites) {
      throw StateError('Simulated disk-full write error #$_writeCount');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
    _inner.write(bytes);
  }

  @override
  Future<void> writeAt(int offset, Uint8List bytes) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    _inner.writeAt(offset, bytes);
  }

  @override
  Future<void> flush() async => _inner.flush();

  @override
  Future<void> close() async => _inner.close();

  Uint8List toBytes() => _inner.toBytes();
}

final class _FailWriteAtBuffer implements RecordingByteBuffer {
  @override
  String? get path => 'broken://buffer';

  @override
  int get lengthInBytes => 0;

  @override
  void write(Uint8List bytes) {}

  @override
  void writeAt(int offset, Uint8List bytes) {
    throw const FileSystemException('Seek / random write unsupported');
  }

  @override
  void flush() {}

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  group('Phase 2 & 3 MemoryRecordingBuffer & Core Robustness', () {
    test('MemoryRecordingBuffer chunking, cross-boundary writeAt, takeBytes, clear', () {
      expect(() => MemoryRecordingBuffer(chunkSizeBytes: 0), throwsArgumentError);

      final buf = MemoryRecordingBuffer(path: 'mem/test.wav', chunkSizeBytes: 8);
      expect(buf.path, equals('mem/test.wav'));
      expect(buf.lengthInBytes, equals(0));
      expect(() => buf.writeAt(-1, Uint8List(2)), throwsRangeError);

      buf.write(Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));
      expect(buf.lengthInBytes, equals(11));
      expect(buf.chunks.length, equals(2));
      expect(() => buf.chunks.first[0] = 99, throwsUnsupportedError);

      // Patch across chunk 0 -> chunk 1 boundary cleanly (offsets 6..9)
      buf.writeAt(6, Uint8List.fromList([60, 70, 80, 90]));
      expect(
        buf.toBytes(),
        equals(Uint8List.fromList([0, 1, 2, 3, 4, 5, 60, 70, 80, 90, 10])),
      );

      final taken = buf.takeBytes();
      expect(taken.length, equals(11));
      expect(buf.lengthInBytes, equals(0));
      expect(buf.toBytes(), isEmpty);

      buf.flush();
      buf.close();
      expect(buf.isClosed, isTrue);
    });

    test('Validates missing target, unsupported mp3/flac, bad URIs, and double startRecording',
        () async {
      final player = MiniaudioPlayer(
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);

      expect(
        () => player.action.startRecording(null),
        throwsArgumentError,
      );

      for (final unsupportedFmt in [AudioFileFormat.mp3, AudioFileFormat.flac]) {
        await expectLater(
          () => player.action.startRecording(
            null,
            buffer: MemoryRecordingBuffer(),
            format: unsupportedFmt,
          ),
          throwsA(
            isA<MiniaudioPlayerException>().having(
              (e) => e.errorCode,
              'errorCode',
              equals(MapResult.errorUnsupported),
            ),
          ),
        );
      }

      for (final badPath in [
        '',
        '   ',
        'https://example.com/rec.wav',
        'asset://audio/rec.wav',
        'package:my_app/rec.wav',
        'opfs://recordings/rec.wav',
        if (!Platform.isAndroid) 'content://media/external/audio/123',
      ]) {
        await expectLater(
          () => player.action.startRecording(badPath),
          throwsA(isA<MiniaudioPlayerException>()),
        );
      }

      // Start one valid MemoryRecordingBuffer recording, then reject a concurrent second startRecording
      final memBuf = MemoryRecordingBuffer();
      await player.action.startRecording(null, buffer: memBuf);
      await expectLater(
        () => player.action.startRecording(null, buffer: MemoryRecordingBuffer()),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorInvalidState),
          ),
        ),
      );
      await player.action.stopRecording();
    });

    test('Records valid PCM16 and Float32 WAV to MemoryRecordingBuffer & prioritizes buffer with warning',
        () async {
      final wavBytes = _generateWavSine(sampleRate: 48000, channels: 2, frequencyHz: 440.0);
      final player = MiniaudioPlayer(
        queue: [AudioSource(wavBytes, data: 'sine440')],
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);

      final warnings = <String>[];
      MiniaudioPlayerGlobalConfig.onLog = (level, msg) {
        if (level == MiniaudioLogLevel.warning) {
          warnings.add(msg);
        }
      };
      addTearDown(() => MiniaudioPlayerGlobalConfig.onLog = null);

      final tempDir = await Directory.systemTemp.createTemp('map_prio_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final ignoredDiskPath = '${tempDir.path}/should_not_exist.wav';

      // Pass BOTH path and buffer -> warning emitted & buffer takes precedence
      final pcmBuf = MemoryRecordingBuffer(path: 'mem://pcm16.wav');
      await player.action.startRecording(
        ignoredDiskPath,
        buffer: pcmBuf,
        format: AudioFileFormat.wav,
      );
      expect(warnings.any((w) => w.contains('Prioritizing RecordingByteBuffer')), isTrue);
      expect(File(ignoredDiskPath).existsSync(), isFalse);
      expect(player.state.isRecording, isTrue);

      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      final res1 = await player.action.stopRecording();
      expect(player.state.isRecording, isFalse);
      expect(res1.path, equals('mem://pcm16.wav'));
      expect(res1.bytesWritten, greaterThan(0));
      expect(res1.droppedFrames, equals(0));
      expect(File(ignoredDiskPath).existsSync(), isFalse);

      final bytes1 = pcmBuf.toBytes();
      expect(bytes1.length, equals(44 + res1.bytesWritten));
      final bd1 = ByteData.sublistView(bytes1);
      expect(String.fromCharCodes(bytes1.sublist(0, 4)), equals('RIFF'));
      expect(bd1.getUint32(4, Endian.little), equals(bytes1.length - 8));
      expect(bd1.getUint16(20, Endian.little), equals(1)); // PCM16
      expect(bd1.getUint16(34, Endian.little), equals(16));
      expect(bd1.getUint32(40, Endian.little), equals(res1.bytesWritten));

      // Verify actual non-zero audio energy in payload
      var maxAmp = 0;
      for (var off = 44; off + 2 <= bytes1.length; off += 2) {
        final s = bd1.getInt16(off, Endian.little).abs();
        if (s > maxAmp) maxAmp = s;
      }
      expect(maxAmp, greaterThan(1500));

      // Now test AudioFileFormat.wavFloat32
      final f32Buf = MemoryRecordingBuffer();
      await player.action.startRecordingToBuffer(
        f32Buf,
        format: AudioFileFormat.wavFloat32,
      );
      await Future<void>.delayed(const Duration(milliseconds: 180));
      final res2 = await player.action.stopRecording();
      final bytes2 = f32Buf.toBytes();
      expect(bytes2.length, equals(44 + res2.bytesWritten));
      final bd2 = ByteData.sublistView(bytes2);
      expect(bd2.getUint16(20, Endian.little), equals(3)); // IEEE Float32
      expect(bd2.getUint16(34, Endian.little), equals(32));
      expect(bd2.getUint32(40, Endian.little), equals(res2.bytesWritten));
    });

    test('Async FIFO buffer ordering, fail-fast writeAt, and mid-recording error propagation',
        () async {
      final wavBytes = _generateWavSine(sampleRate: 48000, channels: 2, frequencyHz: 520.0);
      final player = MiniaudioPlayer(
        queue: [AudioSource(wavBytes, data: 'sine520')],
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);

      // Fail-fast check when writeAt(0) fails during startRecording
      await expectLater(
        () => player.action.startRecordingToBuffer(_FailWriteAtBuffer()),
        throwsA(isA<MiniaudioPlayerException>()),
      );
      expect(player.state.isRecording, isFalse);

      // Healthy async FIFO buffer test
      final asyncBuf = _DelayedAsyncBuffer();
      await player.action.startRecordingToBuffer(asyncBuf);
      await player.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 140));
      final resOk = await player.action.stopRecording();
      final asyncBytes = asyncBuf.toBytes();
      expect(asyncBytes.length, equals(44 + resOk.bytesWritten));
      expect(
        ByteData.sublistView(asyncBytes).getUint32(40, Endian.little),
        equals(resOk.bytesWritten),
      );

      // Mid-recording error propagation -> error stream + stopRecording rethrow
      final errEvents = <MiniaudioPlayerException>[];
      final errSub = player.stream.errors.listen(errEvents.add);
      addTearDown(errSub.cancel);

      final failingAsyncBuf = _DelayedAsyncBuffer(failAfterWrites: 3);
      await player.action.startRecordingToBuffer(failingAsyncBuf);

      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (errEvents.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(errEvents, isNotEmpty);
      await expectLater(
        () => player.action.stopRecording(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
      expect(player.state.isRecording, isFalse);
    });

    test('file:// URI normalization and dispose() auto-finalizes WAV headers on disk & buffer',
        () async {
      final wavBytes = _generateWavSine(sampleRate: 48000, channels: 2, frequencyHz: 330.0);
      final tempDir = await Directory.systemTemp.createTemp('map_uri_disp_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final diskPath = '${tempDir.path}/my encoded file.wav';
      final fileUri = Uri.file(diskPath).toString();

      // 1. file:// URI normalized cleanly -> real finalized disk file without explicit stop() before dispose
      final p1 = MiniaudioPlayer(
        queue: [AudioSource(wavBytes, data: 'd1')],
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      await p1.action.startRecording(fileUri, format: AudioFileFormat.wavFloat32);
      await p1.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 160));
      await p1.dispose();

      final diskFile = File(diskPath);
      expect(diskFile.existsSync(), isTrue);
      final diskBytes = diskFile.readAsBytesSync();
      expect(diskBytes.length, greaterThan(44));
      final diskBd = ByteData.sublistView(diskBytes);
      expect(diskBd.getUint16(20, Endian.little), equals(3)); // Float32 WAV
      expect(diskBd.getUint32(4, Endian.little), equals(diskBytes.length - 8));
      expect(diskBd.getUint32(40, Endian.little), equals(diskBytes.length - 44));

      // 2. MemoryRecordingBuffer auto-finalized on dispose() too
      final memBuf = MemoryRecordingBuffer();
      final p2 = MiniaudioPlayer(
        queue: [AudioSource(wavBytes, data: 'd2')],
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      await p2.action.startRecordingToBuffer(memBuf);
      await p2.action.play();
      await Future<void>.delayed(const Duration(milliseconds: 160));
      await p2.dispose();

      final memBytes = memBuf.toBytes();
      expect(memBytes.length, greaterThan(44));
      final memBd = ByteData.sublistView(memBytes);
      expect(memBd.getUint32(4, Endian.little), equals(memBytes.length - 8));
      expect(memBd.getUint32(40, Endian.little), equals(memBytes.length - 44));
    });

    test(
        'Encodes RF64, W64, AIFF, CAF, and WavPack via disk & RecordingByteBuffer and round-trips through decoder',
        () async {
      final supported = AudioFileFormat.supportedRecordingFormats;
      expect(supported, hasLength(11));
      expect(supported, isNot(contains(AudioFileFormat.mp3)));
      expect(supported, isNot(contains(AudioFileFormat.flac)));

      expect(
        () => AudioFileFormat.aiff.resolveForRecording(wavFormat: WavFormat.float32),
        throwsA(
          isA<MiniaudioPlayerException>().having(
            (e) => e.errorCode,
            'errorCode',
            equals(MapResult.errorUnsupported),
          ),
        ),
      );

      final tempDir = await Directory.systemTemp.createTemp('miniaudio_rec_formats_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final wavBytes = _generateWavSine(
        sampleRate: 48000,
        channels: 2,
        durationSeconds: 1.5,
        frequencyHz: 440.0,
      );
      final player = MiniaudioPlayer(
        queue: [AudioSource(wavBytes, data: 'sine440')],
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);
      await player.action.play();

      final expectedContainer = <AudioFileFormat, String>{
        AudioFileFormat.rf64: 'RF64',
        AudioFileFormat.rf64Float32: 'RF64',
        AudioFileFormat.w64: 'W64',
        AudioFileFormat.w64Float32: 'W64',
        AudioFileFormat.aiff: 'AIFF',
        AudioFileFormat.caf: 'CAF',
        AudioFileFormat.cafFloat32: 'CAF',
        AudioFileFormat.wavPack: 'WavPack',
        AudioFileFormat.wavPackFloat32: 'WavPack',
      };

      for (final entry in expectedContainer.entries) {
        final fmt = entry.key;
        final memBuf = MemoryRecordingBuffer(path: 'mem://rec.${fmt.extension}');
        await player.action.startRecordingToBuffer(memBuf, format: fmt);
        await Future<void>.delayed(const Duration(milliseconds: 90));
        final res = await player.action.stopRecording();
        expect(res.bytesWritten, greaterThan(0), reason: 'zero bytes for $fmt');

        final recorded = memBuf.toBytes();
        final info = (await MiniaudioPlayer.analyzeAudio(
          AudioSource(recorded, data: fmt.name),
          replayGain: false,
          waveform: false,
        ))
            .audioInfo;
        expect(info.sampleRate, equals(48000), reason: 'sampleRate $fmt');
        expect(info.channels, equals(2), reason: 'channels $fmt');
        expect(info.bitsPerSample, equals(fmt.bitsPerSample), reason: 'bps $fmt');
        expect(
          info.containerFormat,
          contains(entry.value),
          reason: 'container $fmt',
        );
        expect(info.duration, greaterThan(Duration.zero), reason: 'dur $fmt');
      }

      for (final fmt in const [
        AudioFileFormat.rf64Float32,
        AudioFileFormat.w64,
        AudioFileFormat.aiff,
        AudioFileFormat.cafFloat32,
        AudioFileFormat.wavPack,
      ]) {
        final filePath = '${tempDir.path}/native_${fmt.name}.${fmt.extension}';
        await player.action.startRecording(filePath, format: fmt);
        await Future<void>.delayed(const Duration(milliseconds: 90));
        final res = await player.action.stopRecording();
        expect(res.bytesWritten, greaterThan(0), reason: 'disk bytes $fmt');
        expect(res.format, equals(fmt));
        expect(res.isOpfs, isFalse);
        expect(File(filePath).existsSync(), isTrue, reason: 'disk exists $fmt');

        final info = (await MiniaudioPlayer.analyzeAudio(
          filePath,
          replayGain: false,
          waveform: false,
        ))
            .audioInfo;
        expect(info.sampleRate, equals(48000), reason: 'disk sr $fmt');
        expect(info.channels, equals(2), reason: 'disk ch $fmt');
        expect(info.bitsPerSample, equals(fmt.bitsPerSample), reason: 'disk bps $fmt');
        expect(
          info.containerFormat,
          contains(expectedContainer[fmt]!),
          reason: 'disk container $fmt',
        );
      }
    });

    test('sanitizeOpfsRecordingPath handles equivalence, invalid-name sanitization, opfs:// stripping, and errors', () {
      final abs = sanitizeOpfsRecordingPath('/temporal/sistema/test/1.wav');
      final rel = sanitizeOpfsRecordingPath('temporal/sistema/test/1.wav');
      final pre = sanitizeOpfsRecordingPath('opfs:///temporal/sistema/test/1.wav');
      final root = sanitizeOpfsRecordingPath('1.wav');
      expect(abs.hasError, isFalse);
      expect(abs.canonicalPath, equals('temporal/sistema/test/1.wav'));
      expect(rel.canonicalPath, equals(abs.canonicalPath));
      expect(pre.canonicalPath, equals(abs.canonicalPath));
      expect(pre.hadOpfsPrefix, isTrue);
      expect(root.canonicalPath, equals('1.wav'));

      final dirty = sanitizeOpfsRecordingPath('/temporal/sistema/bad:name*?.wav');
      expect(dirty.hasError, isFalse);
      expect(dirty.canonicalPath, equals('temporal/sistema/bad_name__.wav'));

      final reserved = sanitizeOpfsRecordingPath('opfs://temporal/CON/aux.. /take .wav.');
      expect(reserved.hasError, isFalse);
      expect(reserved.hadOpfsPrefix, isTrue);
      expect(reserved.canonicalPath, equals('temporal/_CON/_aux/take .wav'));

      final longLeaf = sanitizeOpfsRecordingPath('rec/${'日' * 120}.rf64');
      expect(longLeaf.hasError, isFalse);
      expect(longLeaf.canonicalPath!.endsWith('.rf64'), isTrue);
      final leaf = longLeaf.canonicalPath!.split('/').last;
      expect(utf8.encode(leaf).length, lessThanOrEqualTo(255));
      expect(utf8.encode(leaf).length, greaterThan(100));

      for (final bad in ['', '  ', '/', 'temporal/', '../escape.wav', 'temporal/.../a.wav']) {
        final err = sanitizeOpfsRecordingPath(bad);
        expect(err.errorCode, equals(MapResult.errorInvalidArgs), reason: bad);
      }
      expect(
        sanitizeOpfsRecordingPath('https://example.com/1.wav').errorCode,
        equals(MapResult.errorUnsupported),
      );
    });

    test('RecordingResult exposes fileName, mimeType, readBytes, toAudioSource, saveTo, exists, delete, and download', () async {
      final tempDir = await Directory.systemTemp.createTemp('miniaudio_rec_result_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final wavBytes = _generateWavSine(
        sampleRate: 48000,
        channels: 2,
        durationSeconds: 1.5,
        frequencyHz: 440.0,
      );
      final player = MiniaudioPlayer(
        queue: [AudioSource(wavBytes, data: 'sine440')],
        outputs: const {},
        config: const PlayerConfig(sampleRate: 48000, channels: 2),
      );
      addTearDown(player.dispose);
      await player.action.play();

      final mem = MemoryRecordingBuffer(path: 'takes/mem_take.wv');
      await player.action.startRecordingToBuffer(
        mem,
        format: AudioFileFormat.wavPack,
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      final memRes = await player.action.stopRecording();

      expect(memRes.fileName, equals('mem_take.wv'));
      expect(memRes.mimeType, equals('audio/x-wavpack'));
      expect(memRes.format, equals(AudioFileFormat.wavPack));
      expect(memRes.isInMemory, isTrue);
      expect(memRes.isOpfs, isFalse);
      expect(await memRes.exists(), isTrue);
      expect(await memRes.download(), isFalse);
      expect(await memRes.createBlobUri(), isNull);

      final memBytes = await memRes.readBytes();
      expect(memBytes.sublist(0, 4), equals([0x77, 0x76, 0x70, 0x6B]));

      final memSrc = memRes.toAudioSource<String>(data: 'mem-tag');
      expect(memSrc.isMemory, isTrue);
      expect(memSrc.data, equals('mem-tag'));
      final memAnalysis = await MiniaudioPlayer.analyzeAudio(
        memSrc,
        replayGain: false,
        waveform: false,
      );
      expect(memAnalysis.audioInfo.sampleRate, equals(48000));

      final exportedPath = '${tempDir.path}/exported/copy.wv';
      final savedDest = await memRes.saveTo(exportedPath);
      expect(savedDest, equals(exportedPath));
      expect(File(exportedPath).readAsBytesSync(), equals(memBytes));

      expect(await memRes.delete(), isTrue);
      expect(await memRes.exists(), isFalse);

      // Disk-backed RecordingResult helpers
      final diskRes = RecordingResult(
        path: exportedPath,
        duration: memRes.duration,
        bytesWritten: memBytes.length,
        sampleCount: memRes.sampleCount,
        format: AudioFileFormat.wavPack,
      );
      expect(diskRes.fileName, equals('copy.wv'));
      expect(diskRes.isInMemory, isFalse);
      expect(await diskRes.exists(), isTrue);
      expect(await diskRes.readBytes(), equals(memBytes));
      final diskSrc = diskRes.toAudioSource<int>(data: 42);
      expect(diskSrc.isFile, isTrue);
      expect(diskSrc.data, equals(42));
      expect(await diskRes.delete(), isTrue);
      expect(await diskRes.exists(), isFalse);
    });
  });
}
