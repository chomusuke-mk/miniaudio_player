import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/concurrency_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MiniaudioPlayer.ensureInitialized();
  });

  File resolveAsset(String path) {
    final file = File(path);
    if (file.existsSync()) return file;
    final parentFile = File('../$path');
    if (parentFile.existsSync()) return parentFile;
    return file;
  }

  group('Unified Audio Analysis (ReplayGain, Loudness & Waveform)', () {
    test(
        'analyzeAudio calculates both ReplayGain and Waveform in a single pass on MP3 asset',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue,
          reason: 'Test asset 01_Apex_Momentum.mp3 must exist');

      final result = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: true,
        waveform: true,
        waveformPoints: 100,
        targetLufs: -18.0,
      );

      // Track metadata
      expect(result.audioInfo.duration?.inMilliseconds, greaterThan(0));
      expect(result.audioInfo.sampleRate, equals(48000));
      expect(result.audioInfo.channels, equals(2));
      expect(result.audioInfo.bitrate, greaterThan(0));

      // ReplayGain metrics
      expect(result.replayGain, isNotNull);
      final rg = result.replayGain!;
      expect(rg.peak, greaterThan(0.9));
      expect(
          rg.peak,
          closeTo(1.05,
              0.05)); // True unclipped peak for 01_Apex_Momentum.mp3 (matches ffmpeg track_peak 1.054404)
      expect(rg.lufs,
          closeTo(-12.2, 0.5)); // Expected ~ -12.2 LUFS (matches ffmpeg ebur128)
      expect(
          rg.gainDb,
          closeTo(
              -5.75, 0.5)); // Matches ffmpeg replaygain track_gain -5.75 dB

      // Check recommended volume
      final volWithClippingDefense =
          rg.getRecommendedVolume(preventClipping: true);
      expect(volWithClippingDefense, greaterThan(0.0));
      expect(volWithClippingDefense, lessThanOrEqualTo(1.0));

      // Waveform metrics
      expect(result.waveform, isNotNull);
      final wf = result.waveform!;
      expect(wf.length, equals(100));
      expect(wf.points.length, equals(100));

      // All waveform points should be normalized between 0.0 and 1.0
      for (final pt in wf.points) {
        expect(pt, greaterThanOrEqualTo(0.0));
        expect(pt, lessThanOrEqualTo(1.0));
      }

      // Max normalized point should reach 1.0 due to relative normalization
      final maxPt = wf.points.reduce((a, b) => a > b ? a : b);
      expect(maxPt, closeTo(1.0, 0.001));

      // Progress and position sampling helpers
      expect(wf.getPointAtProgress(0.0), equals(wf.points.first));
      expect(wf.getPointAtProgress(1.0), equals(wf.points.last));
      expect(
          wf.getPointAtPosition(
              Duration.zero, result.audioInfo.duration ?? Duration.zero),
          equals(wf.points.first));
    });

    test('analyzeAudio with only waveform skips ReplayGain calculation',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue);

      final result = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: false,
        waveform: true,
        waveformPoints: 64,
      );

      expect(result.replayGain, isNull);
      expect(result.waveform, isNotNull);
      expect(result.waveform!.length, equals(64));
    });

    test('analyzeAudio with only replayGain skips Waveform extraction',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue);

      final result = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: true,
        waveform: false,
      );

      expect(result.replayGain, isNotNull);
      expect(result.waveform, isNull);
      expect(result.replayGain!.lufs, closeTo(-12.2, 0.5));
    });

    test('analyzeAudioSync calculates loudness and waveform synchronously', () {
      final wav =
          resolveAsset('example/assets/music/17_Running_To_Meet_The_Sun.wav');
      expect(wav.existsSync(), isTrue);

      final result = MiniaudioPlayer.analyzeAudioSync(
        wav.path,
        targetLufs: -14.0,
        waveformPoints: 50,
      );

      expect(result.replayGain, isNotNull);
      expect(result.replayGain!.peak, greaterThan(0.9));
      expect(result.replayGain!.lufs, closeTo(-11.7, 0.5));
      expect(result.replayGain!.gainDb,
          closeTo(-5.41, 0.5)); // Matches ffmpeg replaygain -5.41 dB

      expect(result.waveform, isNotNull);
      expect(result.waveform!.length, equals(50));
    });

    test('analyzes FLAC, OPUS, AAC, and M4A seamlessly across codecs',
        () async {
      final formats = [
        'example/assets/music/04_Belaya_Tishina.flac',
        'example/assets/music/02_Bailando_con_tu_recuerdo.opus',
        'example/assets/music/10_La_cicatriz_del_andén.aac',
        'example/assets/music/06_Calculated_Motion_aac.m4a',
      ];

      for (final relPath in formats) {
        final file = resolveAsset(relPath);
        if (!file.existsSync()) continue;

        final result =
            await MiniaudioPlayer.analyzeAudio(file.path, waveformPoints: 80);
        expect(result.replayGain, isNotNull, reason: 'ReplayGain for $relPath');
        expect(result.replayGain!.peak, greaterThan(0.5),
            reason: 'Peak for $relPath');
        expect(result.replayGain!.lufs, lessThan(0.0),
            reason: 'LUFS for $relPath');
        expect(result.replayGain!.gainDb.isFinite, isTrue,
            reason: 'Gain for $relPath');
        expect(result.waveform, isNotNull, reason: 'Waveform for $relPath');
        expect(result.waveform!.length, equals(80),
            reason: 'Waveform points for $relPath');
      }
    });

    test('analyzes 24-bit WAV fixture with accurate peak and waveform',
        () async {
      final wav24 = resolveAsset(
          'example/assets/music/12_Mi_más_bonita_coincidencia_24bit_stereo.wav');
      expect(wav24.existsSync(), isTrue);

      final result =
          await MiniaudioPlayer.analyzeAudio(wav24.path, waveformPoints: 30);
      expect(result.replayGain, isNotNull);
      expect(result.replayGain!.peak, greaterThan(0.05));
      expect(result.replayGain!.lufs.isFinite, isTrue);
      expect(result.replayGain!.gainDb.isFinite, isTrue);
      expect(result.waveform, isNotNull);
      expect(result.waveform!.length, equals(30));
    });

    test('handles non-existent file cleanly with MiniaudioPlayerException',
        () async {
      expect(
        () => MiniaudioPlayer.analyzeAudio(
            '/path/to/non_existent_file_xyz_123.mp3'),
        throwsA(isA<MiniaudioPlayerException>()),
      );
    });

    test('handles empty file cleanly with MiniaudioPlayerException', () async {
      final tempEmpty = File(
          '${Directory.systemTemp.path}/empty_analysis_${DateTime.now().millisecondsSinceEpoch}.wav');
      try {
        tempEmpty.createSync();
        expect(
          () => MiniaudioPlayer.analyzeAudio(tempEmpty.path),
          throwsA(isA<MiniaudioPlayerException>()),
        );
      } finally {
        if (tempEmpty.existsSync()) {
          tempEmpty.deleteSync();
        }
      }
    });

    test(
        'analyzeAudio accepts AudioSource instances directly for file and memory sources',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue);

      // File AudioSource
      final fileSource = AudioSource(mp3.path);
      final fileRes = await MiniaudioPlayer.analyzeAudio(
        fileSource,
        waveformPoints: 32,
      );
      expect(fileRes.audioInfo.sampleRate, equals(48000));
      expect(fileRes.audioInfo.channels, equals(2));
      expect(fileRes.audioInfo.format, equals('mp3'));
      expect(fileRes.waveform?.length, equals(32));

      // Memory AudioSource
      final bytes = mp3.readAsBytesSync();
      final memSource = AudioSource(bytes);
      final memRes = await MiniaudioPlayer.analyzeAudio(
        memSource,
        waveformPoints: 32,
      );
      expect(memRes.audioInfo.sampleRate, equals(48000));
      expect(memRes.audioInfo.channels, equals(2));
      expect(memRes.audioInfo.format, equals('mp3'));
      expect(memRes.waveform?.length, equals(32));

      // Synchronous analysis with memory source
      final syncMemRes = MiniaudioPlayer.analyzeAudioSync(
        AudioSource(bytes),
        waveformPoints: 16,
      );
      expect(syncMemRes.audioInfo.sampleRate, equals(48000));
      expect(syncMemRes.waveform?.length, equals(16));
    });

    test('analyzeAudio extracts AudioMetadata when metadata: true is requested',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue);

      // Default: metadata == false -> metadata is null
      final noMeta =
          await MiniaudioPlayer.analyzeAudio(mp3.path, metadata: false);
      expect(noMeta.metadata, isNull);

      // metadata == true -> metadata is extracted
      final withMeta =
          await MiniaudioPlayer.analyzeAudio(mp3.path, metadata: true);
      expect(withMeta.metadata, isNotNull);
      expect(withMeta.metadata!.isNotEmpty, isTrue);
      expect(withMeta.metadata!.length, greaterThan(0));
      expect(
          withMeta.metadata!.bytes.length, equals(withMeta.metadata!.length));
    });

    test(
        'analyzeAudio Phase 1 fast path resolves without waveform or replayGain',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue);

      final sw = Stopwatch()..start();
      final fastRes = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        replayGain: false,
        waveform: false,
        metadata: true,
      );
      sw.stop();

      expect(fastRes.replayGain, isNull);
      expect(fastRes.waveform, isNull);
      expect(fastRes.audioInfo.sampleRate, equals(48000));
      expect(fastRes.audioInfo.channels, equals(2));
      expect(fastRes.metadata, isNotNull);
      expect(fastRes.metadata!.isNotEmpty, isTrue);
      // Static header analysis should execute extremely fast (< 100 ms in debug)
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('analyzeAudio with maxAnalysisDuration limits decoded duration',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue);

      final fullRes = await MiniaudioPlayer.analyzeAudio(mp3.path);
      final cappedRes = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        maxAnalysisDuration: const Duration(seconds: 2),
      );

      expect(cappedRes.waveform, isNotNull);
      expect(cappedRes.replayGain?.peak, greaterThan(0.0));
      expect(
          cappedRes.audioInfo.sampleRate, equals(fullRes.audioInfo.sampleRate));
    });

    test('analyzeAudio with chromaprint calculates acoustic fingerprint',
        () async {
      final mp3 = resolveAsset('example/assets/music/01_Apex_Momentum.mp3');
      expect(mp3.existsSync(), isTrue);

      final noCp =
          await MiniaudioPlayer.analyzeAudio(mp3.path, chromaprint: false);
      expect(noCp.chromaprint, isNull);

      final withCp = await MiniaudioPlayer.analyzeAudio(
        mp3.path,
        chromaprint: true,
        maxAnalysisDuration: const Duration(seconds: 5),
      );
      expect(withCp.chromaprint, isNotNull);
      expect(withCp.chromaprint!.fingerprint.isNotEmpty, isTrue);
      expect(withCp.chromaprint!.raw.isNotEmpty, isTrue);
      expect(withCp.chromaprint!.algorithm, greaterThanOrEqualTo(0));
    });
  });

  group('MiniaudioPlayer Metadata and AudioInfo state and stream integration',
      () {
    test('player exposes audioInfo and metadata on state and stream', () async {
      final wav =
          resolveAsset('example/assets/music/17_Running_To_Meet_The_Sun.wav');
      expect(wav.existsSync(), isTrue);

      final source = AudioSource(wav.path);
      final player = MiniaudioPlayer();
      try {
        await player.action.setQueue([source]);
        await player.action.play();

        await awaitStateOrStream<AudioInfo?>(
          stream: player.stream.audioInfo,
          current: () => player.state.audioInfo,
          predicate: (info) => info != null,
          timeout: const Duration(seconds: 2),
          reason: 'AudioInfo should populate on track play',
        );

        expect(player.state.audioInfo, isNotNull);
        expect(player.state.audioInfo?.sampleRate, greaterThan(0));
        expect(player.state.duration, isNotNull);
        expect(player.state.metadataEnabled, isFalse);

        await player.action.setMetadataEnabled(true);
        expect(player.state.metadataEnabled, isTrue);

        await player.action.setMetadataEnabled(false);
        expect(player.state.metadataEnabled, isFalse);
      } finally {
        await player.dispose();
      }
    });
  });

  group('MiniaudioPlayer ReplayGain integration from AudioSource', () {
    test('player applies replay gain from AudioSource automatically on open',
        () async {
      final wav =
          resolveAsset('example/assets/music/17_Running_To_Meet_The_Sun.wav');
      expect(wav.existsSync(), isTrue);

      final source = AudioSource(
        wav.path,
        replayGainDb: -6.5,
        replayPeak: 0.95,
      );

      expect(source.replayGainDb, equals(-6.5));
      expect(source.replayPeak, equals(0.95));

      final player = MiniaudioPlayer(queue: [source]);
      try {
        await awaitStateOrStream<ReplayGainConfig>(
          stream: player.stream.replayGain,
          current: () => player.state.replayGain,
          predicate: (rg) => rg.gainDb != 0.0,
          timeout: const Duration(seconds: 2),
          reason: 'Constructor queue failed to apply ReplayGain metadata',
        );

        expect(player.state.replayGainMode, equals(ReplayGainMode.track));
        expect(player.state.replayGain.gainDb, closeTo(-6.5, 1e-4));
        expect(player.state.replayGain.peak, closeTo(0.95, 1e-4));

        // Queueing another source with new replay gain applies it
        final source2 = AudioSource(
          wav.path,
          replayGainDb: -3.0,
          replayPeak: 0.8,
        );
        await player.action.setQueue([source2]);

        expect(player.state.replayGain.gainDb, closeTo(-3.0, 1e-4));
        expect(player.state.replayGain.peak, closeTo(0.8, 1e-4));

        // Clearing replay gain by passing null resets it to default fallback
        await player.action.setReplayGain(null);
        expect(player.state.replayGain.gainDb, closeTo(0.0, 1e-4));
      } finally {
        await player.dispose();
      }
    });
  });

  group('Per-Track ReplayGain Crossfade Isolation (End-to-End)', () {
    File writeSineWav16(
      Directory dir,
      String name, {
      required int sampleRate,
      required int frames,
      required double freqHz,
      required double amplitude,
    }) {
      const channels = 2;
      final dataSize = frames * channels * 2;
      final bytes = ByteData(44 + dataSize);
      void writeTag(int offset, String tag) {
        for (int i = 0; i < 4; i++) {
          bytes.setUint8(offset + i, tag.codeUnitAt(i));
        }
      }

      writeTag(0, 'RIFF');
      bytes.setUint32(4, 36 + dataSize, Endian.little);
      writeTag(8, 'WAVE');
      writeTag(12, 'fmt ');
      bytes.setUint32(16, 16, Endian.little);
      bytes.setUint16(20, 1, Endian.little); // PCM
      bytes.setUint16(22, channels, Endian.little);
      bytes.setUint32(24, sampleRate, Endian.little);
      bytes.setUint32(28, sampleRate * channels * 2, Endian.little);
      bytes.setUint16(32, channels * 2, Endian.little);
      bytes.setUint16(34, 16, Endian.little);
      writeTag(36, 'data');
      bytes.setUint32(40, dataSize, Endian.little);

      final twoPiFOverSr = 2.0 * math.pi * freqHz / sampleRate;
      int pos = 44;
      for (int f = 0; f < frames; f++) {
        final sample =
            (amplitude * math.sin(twoPiFOverSr * f) * 32767.0)
                .round()
                .clamp(-32768, 32767);
        bytes.setInt16(pos, sample, Endian.little);
        bytes.setInt16(pos + 2, sample, Endian.little);
        pos += 4;
      }

      final file = File('${dir.path}/$name');
      file.writeAsBytesSync(bytes.buffer.asUint8List());
      return file;
    }

    ({int sampleRate, int channels, Int16List pcm}) parseWavPcm16(
      Uint8List wavBytes,
    ) {
      final bd = ByteData.sublistView(wavBytes);
      int sr = 48000;
      int ch = 2;
      int off = 12;
      while (off + 8 <= wavBytes.length) {
        final id = String.fromCharCodes(wavBytes.sublist(off, off + 4));
        final len = bd.getUint32(off + 4, Endian.little);
        off += 8;
        if (id == 'fmt ' && off + 16 <= wavBytes.length) {
          ch = bd.getUint16(off + 2, Endian.little);
          sr = bd.getUint32(off + 4, Endian.little);
        } else if (id == 'data') {
          final byteLen = math.min(len, wavBytes.length - off);
          final sampleCount = byteLen ~/ 2;
          final pcm = Int16List(sampleCount);
          for (int i = 0; i < sampleCount; i++) {
            pcm[i] = bd.getInt16(off + i * 2, Endian.little);
          }
          return (sampleRate: sr, channels: ch, pcm: pcm);
        }
        off += len + (len.isOdd ? 1 : 0);
      }
      fail('Recorded WAV missing RIFF data chunk');
    }

    double measureToneAmplitudeCh0(
      Int16List pcm,
      int sampleRate,
      int channels,
      double freqHz,
      int startFrame,
      int numFrames,
    ) {
      final w = 2.0 * math.pi * freqHz / sampleRate;
      double cSum = 0.0;
      double sSum = 0.0;
      for (int i = 0; i < numFrames; i++) {
        final sample = pcm[(startFrame + i) * channels] / 32768.0;
        final angle = w * i;
        cSum += sample * math.cos(angle);
        sSum += sample * math.sin(angle);
      }
      return (2.0 / numFrames) * math.sqrt(cSum * cSum + sSum * sSum);
    }

    test(
        'manual crossfade isolates per-track ReplayGain (400 Hz @ -18 dB -> 3200 Hz @ 0 dB) in recorded mix',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('map_rg_manual_xfade_');
      const sr = 48000;
      const baseAmp = 0.4;
      const gainXDb = -18.0;
      final expectedX = baseAmp * math.pow(10.0, gainXDb / 20.0).toDouble();
      const expectedY = baseAmp;

      final wavX = writeSineWav16(
        tempDir,
        'track_x_400hz.wav',
        sampleRate: sr,
        frames: sr * 5,
        freqHz: 400.0,
        amplitude: baseAmp,
      );
      final wavY = writeSineWav16(
        tempDir,
        'track_y_3200hz.wav',
        sampleRate: sr,
        frames: sr * 5,
        freqHz: 3200.0,
        amplitude: baseAmp,
      );
      final recSoloFile = File('${tempDir.path}/solo_x.wav');
      final recXfadeFile = File('${tempDir.path}/manual_xfade.wav');

      final player = MiniaudioPlayer(
        config: const PlayerConfig(
          sampleRate: sr,
          channels: 2,
          crossfade: CrossfadeConfig(
            manualDuration: Duration(milliseconds: 900),
            autoDuration: Duration(milliseconds: 900),
            curve: CrossfadeCurve.linear,
          ),
        ),
      );

      try {
        await player.action.setLimiter(false);
        final sourceX = AudioSource(
          wavX.path,
          replayGainDb: gainXDb,
          replayPeak: 1.0,
        );
        final sourceY = AudioSource(
          wavY.path,
          replayGainDb: 0.0,
          replayPeak: 1.0,
        );

        await player.action.setQueue([sourceX, sourceY]);
        await player.action.play();
        await waitForAudioProgress(
          player,
          minDelta: const Duration(milliseconds: 60),
        );
        expect(player.state.replayGain.gainDb, closeTo(gainXDb, 1e-4));

        // 1. Verify solo Track X uses single -18 dB gain (not double-scaled).
        await player.action.startRecording(
          recSoloFile.path,
          format: AudioFileFormat.wav,
          source: AudioOutputSource.musicMix,
        );
        await waitForRecordingProgress(
          player,
          minRecorded: const Duration(milliseconds: 120),
        );
        await player.action.stopRecording();

        final soloWav = parseWavPcm16(await recSoloFile.readAsBytes());
        final soloWin = soloWav.sampleRate ~/ 20; // 50ms -> exact integer cycles of 400 & 3200 Hz
        final soloTotalFrames = soloWav.pcm.length ~/ soloWav.channels;
        expect(soloTotalFrames, greaterThanOrEqualTo(soloWin * 2));
        final soloAmpX = measureToneAmplitudeCh0(
          soloWav.pcm,
          soloWav.sampleRate,
          soloWav.channels,
          400.0,
          soloWin,
          soloWin,
        );
        final soloAmpY = measureToneAmplitudeCh0(
          soloWav.pcm,
          soloWav.sampleRate,
          soloWav.channels,
          3200.0,
          soloWin,
          soloWin,
        );
        expect(soloAmpX, closeTo(expectedX, 0.008));
        expect(soloAmpY, lessThan(0.003));

        // 2. Record across manual crossfade to Track Y (0 dB).
        await player.action.startRecording(
          recXfadeFile.path,
          format: AudioFileFormat.wav,
          source: AudioOutputSource.musicMix,
        );
        await player.action.next();
        await awaitStateOrStream<bool>(
          stream: player.stream.isCrossfading,
          current: () => player.state.isCrossfading,
          predicate: (v) => v,
          timeout: const Duration(seconds: 3),
          reason: 'Expected manual crossfade to become active',
        );
        expect(player.state.replayGain.gainDb, closeTo(0.0, 1e-4));

        await waitForRecordingProgress(
          player,
          minRecorded: const Duration(milliseconds: 800),
        );
        await player.action.stopRecording();

        final cfWav = parseWavPcm16(await recXfadeFile.readAsBytes());
        final winFrames = cfWav.sampleRate ~/ 20;
        final totalFrames = cfWav.pcm.length ~/ cfWav.channels;
        int overlappingWindows = 0;
        for (int start = 0; start + winFrames <= totalFrames; start += winFrames) {
          final ax = measureToneAmplitudeCh0(
            cfWav.pcm,
            cfWav.sampleRate,
            cfWav.channels,
            400.0,
            start,
            winFrames,
          );
          final ay = measureToneAmplitudeCh0(
            cfWav.pcm,
            cfWav.sampleRate,
            cfWav.channels,
            3200.0,
            start,
            winFrames,
          );
          if (ax > 0.006 && ay > 0.05 && ay < expectedY * 0.90) {
            overlappingWindows++;
            // Track X must never receive Track Y's 0 dB gain while fading out.
            expect(ax, lessThanOrEqualTo(expectedX * 1.15));
            final normSum = (ax / expectedX) + (ay / expectedY);
            expect(normSum, closeTo(1.0, 0.25));
          }
        }
        expect(
          overlappingWindows,
          greaterThanOrEqualTo(2),
          reason: 'Expected multiple overlapping crossfade windows in recorded mix',
        );
      } finally {
        if (player.state.isRecording) {
          try {
            await player.action.stopRecording();
          } catch (_) {}
        }
        await player.dispose();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test(
        'auto crossfade isolates per-track ReplayGain (400 Hz @ 0 dB -> 3200 Hz @ -18 dB) in recorded mix',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('map_rg_auto_xfade_');
      const sr = 48000;
      const baseAmp = 0.4;
      const gainYDb = -18.0;
      const expectedX = baseAmp;
      final expectedY = baseAmp * math.pow(10.0, gainYDb / 20.0).toDouble();

      // 1.7s Track X + 900ms auto crossfade triggers automatically at ~800ms.
      final wavX = writeSineWav16(
        tempDir,
        'auto_x_400hz.wav',
        sampleRate: sr,
        frames: (sr * 1.7).round(),
        freqHz: 400.0,
        amplitude: baseAmp,
      );
      final wavY = writeSineWav16(
        tempDir,
        'auto_y_3200hz.wav',
        sampleRate: sr,
        frames: sr * 4,
        freqHz: 3200.0,
        amplitude: baseAmp,
      );
      final recAutoFile = File('${tempDir.path}/auto_xfade.wav');

      final player = MiniaudioPlayer(
        config: const PlayerConfig(
          sampleRate: sr,
          channels: 2,
          crossfade: CrossfadeConfig(
            manualDuration: Duration(milliseconds: 900),
            autoDuration: Duration(milliseconds: 900),
            curve: CrossfadeCurve.linear,
          ),
        ),
      );

      try {
        await player.action.setLimiter(false);
        final sourceX = AudioSource(wavX.path, replayGainDb: 0.0, replayPeak: 1.0);
        final sourceY =
            AudioSource(wavY.path, replayGainDb: gainYDb, replayPeak: 1.0);
        await player.action.setQueue([sourceX, sourceY]);
        await player.action.play();
        await player.action.startRecording(
          recAutoFile.path,
          format: AudioFileFormat.wav,
          source: AudioOutputSource.musicMix,
        );

        await awaitStateOrStream<bool>(
          stream: player.stream.isCrossfading,
          current: () => player.state.isCrossfading,
          predicate: (v) => v,
          timeout: const Duration(seconds: 5),
          reason: 'Expected auto crossfade to engage near end of Track X',
        );
        // Auto-crossfade keeps outgoing Track X as foreground item until completion,
        // so foreground telemetry stays at 0.0 dB while Track Y fades in at -18 dB.
        expect(player.state.replayGain.gainDb, closeTo(0.0, 1e-4));

        await waitForRecordingProgress(
          player,
          minRecorded:
              player.state.recordedDuration + const Duration(milliseconds: 550),
        );
        await player.action.stopRecording();

        // Once auto-crossfade completes, currentItem and ReplayGain telemetry switch to Track Y (-18 dB).
        await awaitStateOrStream<bool>(
          stream: player.stream.isCrossfading,
          current: () => player.state.isCrossfading,
          predicate: (v) => !v,
          timeout: const Duration(seconds: 5),
          reason: 'Expected auto crossfade to finish onto Track Y',
        );
        await awaitStateOrStream<ReplayGainConfig>(
          stream: player.stream.replayGain,
          current: () => player.state.replayGain,
          predicate: (rg) => (rg.gainDb - gainYDb).abs() < 1e-4,
          timeout: const Duration(seconds: 3),
          reason: 'Expected foreground ReplayGain to switch to -18 dB after auto crossfade',
        );
        expect(player.state.currentItem?.id, equals(sourceY.id));

        final cfWav = parseWavPcm16(await recAutoFile.readAsBytes());
        final winFrames = cfWav.sampleRate ~/ 20;
        final totalFrames = cfWav.pcm.length ~/ cfWav.channels;
        int overlappingWindows = 0;
        for (int start = 0; start + winFrames <= totalFrames; start += winFrames) {
          final ax = measureToneAmplitudeCh0(
            cfWav.pcm,
            cfWav.sampleRate,
            cfWav.channels,
            400.0,
            start,
            winFrames,
          );
          final ay = measureToneAmplitudeCh0(
            cfWav.pcm,
            cfWav.sampleRate,
            cfWav.channels,
            3200.0,
            start,
            winFrames,
          );
          if (ax > 0.04 && ax < expectedX * 0.90 && ay > 0.005) {
            overlappingWindows++;
            // Track Y must never receive Track X's 0 dB gain during auto-crossfade.
            expect(ay, lessThanOrEqualTo(expectedY * 1.15));
            final normSum = (ax / expectedX) + (ay / expectedY);
            expect(normSum, closeTo(1.0, 0.25));
          }
        }
        expect(
          overlappingWindows,
          greaterThanOrEqualTo(2),
          reason: 'Expected overlapping auto-crossfade windows in recorded mix',
        );
      } finally {
        if (player.state.isRecording) {
          try {
            await player.action.stopRecording();
          } catch (_) {}
        }
        await player.dispose();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test(
        'shuffle + outgoing setReplayGain and ReplayGainMode toggles mid-crossfade preserve foreground isolation',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('map_rg_state_xfade_');
      const sr = 48000;
      final wavX = writeSineWav16(
        tempDir,
        'state_x.wav',
        sampleRate: sr,
        frames: sr * 6,
        freqHz: 400.0,
        amplitude: 0.35,
      );
      final wavY = writeSineWav16(
        tempDir,
        'state_y.wav',
        sampleRate: sr,
        frames: sr * 6,
        freqHz: 3200.0,
        amplitude: 0.35,
      );

      final player = MiniaudioPlayer(
        config: const PlayerConfig(
          sampleRate: sr,
          channels: 2,
          crossfade: CrossfadeConfig(
            manualDuration: Duration(milliseconds: 1600),
            autoDuration: Duration(milliseconds: 1600),
            curve: CrossfadeCurve.linear,
          ),
        ),
      );

      try {
        final sourceX = AudioSource(
          wavX.path,
          replayGainDb: -14.0,
          replayPeak: 0.95,
        );
        final sourceY = AudioSource(
          wavY.path,
          replayGainDb: -2.5,
          replayPeak: 0.85,
        );

        await player.action.setQueue([sourceX, sourceY]);
        await player.action.setShuffle(true);
        await player.action.play(id: sourceX.id);
        await waitForAudioProgress(
          player,
          minDelta: const Duration(milliseconds: 50),
        );
        expect(player.state.replayGain.gainDb, closeTo(-14.0, 1e-4));

        await player.action.next();
        await awaitStateOrStream<bool>(
          stream: player.stream.isCrossfading,
          current: () => player.state.isCrossfading,
          predicate: (v) => v,
          timeout: const Duration(seconds: 3),
        );
        expect(player.state.currentItem?.id, equals(sourceY.id));
        expect(player.state.replayGain.gainDb, closeTo(-2.5, 1e-4));

        // Live ReplayGain update targeted at outgoing sourceX under shuffle
        // must update sourceX without hijacking foreground -2.5 dB telemetry.
        await player.action.setReplayGain(
          const ReplayGainConfig(gainDb: -9.0, peak: 0.9),
          id: sourceX.id,
        );
        await drainBroadcastStreams();
        expect(sourceX.replayGainDb, closeTo(-9.0, 1e-4));
        expect(player.state.replayGain.gainDb, closeTo(-2.5, 1e-4));

        // Toggling ReplayGain modes mid-crossfade cleanly updates & restores active gain.
        await player.action.setReplayGainMode(ReplayGainMode.disabled);
        expect(player.state.replayGain.gainDb, closeTo(0.0, 1e-4));

        await player.action.setDefaultReplayGain(-7.5, peak: 0.95);
        await player.action.setReplayGainMode(ReplayGainMode.forced);
        expect(player.state.replayGain.gainDb, closeTo(-7.5, 1e-4));

        await player.action.setReplayGainMode(ReplayGainMode.track);
        expect(player.state.replayGain.gainDb, closeTo(-2.5, 1e-4));

        // Wait for crossfade completion and verify active Track Y update propagates cleanly.
        await awaitStateOrStream<bool>(
          stream: player.stream.isCrossfading,
          current: () => player.state.isCrossfading,
          predicate: (v) => !v,
          timeout: const Duration(seconds: 5),
        );
        await player.action.setReplayGain(
          const ReplayGainConfig(gainDb: -4.5, peak: 0.75),
        );
        expect(player.state.replayGain.gainDb, closeTo(-4.5, 1e-4));
      } finally {
        await player.dispose();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
