import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

/// Synthesizes a valid 24-bit stereo 44.1 kHz WAV file with a standard 44-byte
/// RIFF/WAVE header (`dataChunkDataPos = 44`, where `44 % 6 == 2`) containing
/// a clean low-amplitude 440 Hz sine wave (`amplitude = 0.12`).
Uint8List synthesize24BitStereoWav({
  int sampleRate = 44100,
  int durationSeconds = 8,
  double amplitude = 0.12,
}) {
  const int channels = 2;
  const int bytesPerSample = 3; // 24-bit
  const int bytesPerFrame = channels * bytesPerSample; // 6 bytes
  final int totalFrames = sampleRate * durationSeconds;
  final int dataSize = totalFrames * bytesPerFrame;
  final int fileSize = 44 + dataSize;

  final bytes = Uint8List(fileSize);
  final bd = ByteData.sublistView(bytes);

  // RIFF header (12 bytes)
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  bd.setUint32(4, fileSize - 8, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);

  // fmt chunk (24 bytes)
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  bd.setUint32(16, 16, Endian.little); // PCM fmt chunk size
  bd.setUint16(20, 1, Endian.little); // AudioFormat = 1 (PCM)
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * bytesPerFrame, Endian.little); // ByteRate
  bd.setUint16(32, bytesPerFrame, Endian.little); // BlockAlign = 6
  bd.setUint16(34, 24, Endian.little); // BitsPerSample = 24

  // data chunk header (8 bytes) -> audio starts at offset 44 (44 % 6 == 2)
  bytes.setRange(36, 40, 'data'.codeUnits);
  bd.setUint32(40, dataSize, Endian.little);

  const double twoPiF = 2.0 * pi * 440.0;
  int offset = 44;
  for (int i = 0; i < totalFrames; i++) {
    final double s = sin((twoPiF * i) / sampleRate) * amplitude;
    int pcm24 = (s * 8388607.0).round().clamp(-8388608, 8388607);
    if (pcm24 < 0) pcm24 += 0x1000000;
    final int b0 = pcm24 & 0xFF;
    final int b1 = (pcm24 >> 8) & 0xFF;
    final int b2 = (pcm24 >> 16) & 0xFF;
    // Left channel
    bytes[offset] = b0;
    bytes[offset + 1] = b1;
    bytes[offset + 2] = b2;
    // Right channel
    bytes[offset + 3] = b0;
    bytes[offset + 4] = b1;
    bytes[offset + 5] = b2;
    offset += 6;
  }

  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('Regression Suite: 6 Reported Playback, Seeking & Streaming Issues', () {
    test(
      'Issue 1: Local AAC (ADTS) seek advances C stream read_cursor to target ADTS frame instead of restarting from byte 0',
      () async {
        final player = MiniaudioPlayer();
        try {
          const aacPath = 'example/assets/music/salida.aac';
          final fileLen = File(aacPath).lengthSync();

          await player.action.openFile(aacPath);
          final durMs = player.state.duration.inMilliseconds;
          expect(durMs, greaterThan(15000));

          // Seek to 10 seconds (~14% of 72s track = ~246 KB)
          await player.action.seek(const Duration(seconds: 10));
          final status10s = player.backend.getStreamStatus()!;
          expect(
            (player.state.position.inMilliseconds - 10000).abs(),
            lessThan(500),
          );
          expect(
            status10s.readCursorByte,
            greaterThan(fileLen ~/ 10),
            reason:
                'AAC seek to 10s must advance read_cursor to ~246 KB, not reset to 0 (was ${status10s.readCursorByte} / $fileLen)',
          );

          // Seek to 30 seconds (~42% of 72s track = ~740 KB)
          await player.action.seek(const Duration(seconds: 30));
          final status30s = player.backend.getStreamStatus()!;
          expect(
            (player.state.position.inMilliseconds - 30000).abs(),
            lessThan(500),
          );
          expect(
            status30s.readCursorByte,
            greaterThan(status10s.readCursorByte + (fileLen ~/ 5)),
            reason:
                'AAC seek to 30s must advance read_cursor beyond 10s offset (${status30s.readCursorByte} vs ${status10s.readCursorByte})',
          );

          // Play briefly and verify read_cursor stays in the 30s region
          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final statusAfterPlay = player.backend.getStreamStatus()!;
          expect(
            statusAfterPlay.readCursorByte,
            greaterThanOrEqualTo(status30s.readCursorByte),
          );
        } finally {
          await player.dispose();
        }
      },
    );

    test(
      'Issue 2: Local OGG and OGA seek executes in < 10 ms via OggS page-header hopping',
      () async {
        for (final path in [
          'example/assets/music/salida.ogg',
          'example/assets/music/salida.oga',
        ]) {
          final player = MiniaudioPlayer();
          try {
            await player.action.openFile(path);
            expect(player.state.duration.inMilliseconds, greaterThan(15000));

            final targets = [
              const Duration(seconds: 22),
              const Duration(seconds: 5),
              const Duration(seconds: 18),
              const Duration(seconds: 12),
              Duration.zero,
            ];

            for (final t in targets) {
              final sw = Stopwatch()..start();
              await player.action.seek(t);
              sw.stop();
              expect(
                sw.elapsedMilliseconds,
                lessThan(15),
                reason:
                    'Seek to ${t.inSeconds}s on $path took ${sw.elapsedMilliseconds} ms (must be instant via OggS page-header hop)',
              );
              expect(
                (player.state.position.inMilliseconds - t.inMilliseconds).abs(),
                lessThan(500),
              );
            }
          } finally {
            await player.dispose();
          }
        }
      },
    );

    test(
      'Issue 3: Remote progressive stream resumes from backpressure at ~82% headroom without double-pause deadlock or infinite buffering',
      () async {
        final mp3Bytes = await File('example/assets/music/salida.mp3').readAsBytes();
        // Repeat MP3 payload to create a ~3.5 MB remote file
        final builder = BytesBuilder(copy: false);
        for (int i = 0; i < 7; i++) {
          builder.add(mp3Bytes);
        }
        final largePayload = builder. takeBytes();

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((HttpRequest req) async {
          int start = 0;
          int end = largePayload.length - 1;
          final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
          req.response.headers.set('Accept-Ranges', 'bytes');
          req.response.headers.contentType = ContentType('audio', 'mpeg');
          if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
            final parts = rangeHeader.substring(6).split('-');
            start = int.tryParse(parts[0]) ?? 0;
            if (parts.length > 1 && parts[1].isNotEmpty) {
              end = int.tryParse(parts[1]) ?? end;
            }
            req.response.statusCode = HttpStatus.partialContent;
            req.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${largePayload.length}',
            );
          } else {
            req.response.statusCode = HttpStatus.ok;
          }
          final contentLen = end - start + 1;
          req.response.contentLength = contentLen;

          // Stream in 16 KB chunks so listen() pause/resume is exercised on every chunk
          const chunkSize = 16384;
          int offset = start;
          try {
            while (offset <= end) {
              final int chunkEnd = min(offset + chunkSize, end + 1);
              req.response.add(
                Uint8List.sublistView(largePayload, offset, chunkEnd),
              );
              await req.response.flush();
              offset = chunkEnd;
              await Future<void>.delayed(const Duration(milliseconds: 2));
            }
            await req.response.close();
          } catch (_) {}
        });

        final player = MiniaudioPlayer();
        try {
          final url = 'http://127.0.0.1:${server.port}/track.mp3';
          await player.action.openUrl(
            url,
            bufferAhead: const Duration(seconds: 4),
            bufferBehind: const Duration(seconds: 2),
          );

          final loader = player.streamer!;
          // Wait until backpressure pauses the stream at maxAheadBytes
          int waitedMs = 0;
          while (loader.state != UnifiedLoaderState.pausedByBackpressure &&
              waitedMs < 3000) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            waitedMs += 25;
          }
          expect(
            loader.state,
            equals(UnifiedLoaderState.pausedByBackpressure),
            reason: 'Loader must enter pausedByBackpressure once ahead window is full',
          );

          final int rangeEndAtPause = loader.rangeEnd;
          final int cursorAtPause = loader.readCursorByte;
          final int headroomAtPause = loader.aheadHeadroomBytes;
          expect(rangeEndAtPause, lessThan(largePayload.length));

          // Now perform an in-RAM cache-hit seek that advances readCursorByte by 30% of headroomAtPause
          // (leaving ~70% ahead headroom, which is below the 82% resume watermark!)
          final int targetByteAfterSeek =
              cursorAtPause + (headroomAtPause * 0.35).round();
          final int totalDurMs = player.state.duration.inMilliseconds;
          final int seekMs =
              ((targetByteAfterSeek / largePayload.length) * totalDurMs).round();

          await player.action.seek(Duration(milliseconds: max(1000, seekMs)));

          // Wait briefly and verify the stream automatically resumed at <82% headroom
          // and loaded more bytes into rangeEnd without needing a cache-miss or hitting 0 headroom!
          waitedMs = 0;
          while (loader.rangeEnd <= rangeEndAtPause && waitedMs < 2000) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            loader.onEngineTelemetryTick();
            waitedMs += 25;
          }

          expect(
            loader.rangeEnd,
            greaterThan(rangeEndAtPause),
            reason:
                'rangeEnd must advance progressively before playhead reaches end of preloaded window',
          );
          expect(player.state.buffering, isFalse);
        } finally {
          await player.dispose();
          await server.close(force: true);
        }
      },
    );

    test(
      'Issue 4: 24-bit stereo WAV seek (44-byte header, 6-byte frame) preserves exact 6-byte frame alignment and clean audio without white noise',
      () async {
        final wavBytes = synthesize24BitStereoWav(
          sampleRate: 44100,
          durationSeconds: 8,
          amplitude: 0.12,
        );

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((HttpRequest req) async {
          int start = 0;
          int end = wavBytes.length - 1;
          final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
          req.response.headers.set('Accept-Ranges', 'bytes');
          req.response.headers.contentType = ContentType('audio', 'wav');
          if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
            final parts = rangeHeader.substring(6).split('-');
            start = int.tryParse(parts[0]) ?? 0;
            if (parts.length > 1 && parts[1].isNotEmpty) {
              end = int.tryParse(parts[1]) ?? end;
            }
            req.response.statusCode = HttpStatus.partialContent;
            req.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${wavBytes.length}',
            );
          } else {
            req.response.statusCode = HttpStatus.ok;
          }
          req.response.contentLength = end - start + 1;
          req.response.add(Uint8List.sublistView(wavBytes, start, end + 1));
          await req.response.close();
        });

        final player = MiniaudioPlayer();
        try {
          await player.action.setVisualizerEnabled(true);

          final url = 'http://127.0.0.1:${server.port}/space_force_24bit.wav';
          await player.action.openUrl(url);

          final int audioStart = player.backend.getAudioDataOffset();
          expect(audioStart, equals(44));

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 150));

          // Perform multiple seeks (both cache-hit and cache-miss) to arbitrary millisecond positions
          for (final posMs in [1234, 3456, 789, 5432, 2109, 4321]) {
            await player.action.seek(Duration(milliseconds: posMs));
            await Future<void>.delayed(const Duration(milliseconds: 120));

            final status = player.backend.getStreamStatus()!;
            expect(
              (status.readCursorByte - audioStart) % 6,
              equals(0),
              reason:
                  '24-bit stereo WAV read_cursor (${status.readCursorByte}) must be 6-byte frame aligned relative to audioStart ($audioStart) after seek to $posMs ms',
            );

            final vis = player.state.visualizer;
            expect(
              vis.peak,
              lessThan(0.30),
              reason:
                  'Decoded 24-bit WAV peak after seek to $posMs ms must remain near 0.12 sine amplitude, never full-scale white noise (peak=${vis.peak})',
            );
          }
        } finally {
          await player.dispose();
          await server.close(force: true);
        }
      },
    );

    test(
      'Issue 5 & 6: Livestream opened via AudioSource.network auto-detects live mode, recovers from 2x speed starvation when returning to 1x, and allows pause during buffering',
      () async {
        final mp3Bytes = await File('example/assets/music/salida.mp3').readAsBytes();
        final controllers = <StreamController<Uint8List>>[];

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((HttpRequest req) async {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType('audio', 'mpeg');
          req.response.headers.set('icy-name', 'Test Live Stream');
          req.response.bufferOutput = false;

          final ctrl = StreamController<Uint8List>();
          controllers.add(ctrl);
          // Send initial 64 KB burst so openStream probes immediately
          req.response.add(Uint8List.sublistView(mp3Bytes, 0, 65536));
          await req.response.flush();

          await for (final chunk in ctrl.stream) {
            try {
              req.response.add(chunk);
              await req.response.flush();
            } catch (_) {
              break;
            }
          }
          try {
            await req.response.close();
          } catch (_) {}
        });

        final player = MiniaudioPlayer();
        try {
          // Issue 6: Open live stream as a regular NetworkAudioSource (without isLive: true)
          final liveUri = Uri.parse('http://127.0.0.1:${server.port}/live.mp3');
          expect(
            AudioSource.liveStream(liveUri),
            isA<NetworkAudioSource>(),
            reason: 'LiveStreamAudioSource must be unified under NetworkAudioSource',
          );

          await player.action.open(AudioSource.network(liveUri));
          expect(
            player.state.trackMetadata?.isLiveStream,
            isTrue,
            reason:
                'AudioSource.network must automatically detect live stream from HTTP headers',
          );

          // Issue 5: Play at 2.0x to drain initial buffer and catch up to live edge
          await player.action.setRate(2.0);
          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 500));

          // Switch back to 1.0x and feed 16 KB of live data (> 8 KB live rebuffer threshold)
          await player.action.setRate(1.0);
          for (final ctrl in controllers) {
            if (!ctrl.isClosed) {
              ctrl.add(Uint8List.sublistView(mp3Bytes, 65536, 65536 + 24576));
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));

          final statusAfterRecovery = player.backend.getStreamStatus()!;
          expect(
            statusAfterRecovery.isBuffering,
            isFalse,
            reason:
                'Returning to 1x and receiving >= 8 KB live cushion must clear buffering state',
          );
          expect(
            player.state.buffering,
            isFalse,
            reason: 'Player buffering state must be false after 1x recovery',
          );

          // Verify pause works immediately and clears buffering even if buffering was active
          player.notifyBuffering(true);
          expect(player.state.buffering, isTrue);
          await player.action.pause();
          expect(player.state.playing, isFalse);
          expect(
            player.state.buffering,
            isFalse,
            reason: 'Pausing must always clear buffering state',
          );
        } finally {
          for (final ctrl in controllers) {
            await ctrl.close();
          }
          await player.dispose();
          await server.close(force: true);
        }
      },
    );
  });
}

