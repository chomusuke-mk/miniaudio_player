import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import 'helpers/synthetic_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File sampleWav;
  late Uint8List sampleWavBytes;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('reactive_dispatcher_test_');
    sampleWavBytes = SyntheticAudioGenerator.generateWavBytes(
      durationSeconds: 1.5,
      frequencyHz: 440.0,
      sampleRate: 44100,
      numChannels: 2,
    );
    sampleWav = File('${tempDir.path}/test_tone.wav');
    await sampleWav.writeAsBytes(sampleWavBytes, flush: true);
  });

  tearDownAll(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Reactive C Event Dispatcher - Non-Optimistic Stream Verification', () {
    test('Setters do not emit stream events before C confirms them', () async {
      final player = MiniaudioPlayer();
      try {
        await player.action.open(AudioSource.file(sampleWav.path));

        // Volume
        final volumeEvents = <double>[];
        final volSub = player.stream.volume.listen(volumeEvents.add);

        await player.action.setVolume(0.65);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(volumeEvents, contains(closeTo(0.65, 0.001)));
        expect(player.state.volume, closeTo(0.65, 0.001));
        await volSub.cancel();

        // Rate
        final rateEvents = <double>[];
        final rateSub = player.stream.rate.listen(rateEvents.add);

        await player.action.setRate(1.25);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(rateEvents, contains(closeTo(1.25, 0.001)));
        expect(player.state.rate, closeTo(1.25, 0.001));
        await rateSub.cancel();

        // Pitch
        final pitchEvents = <double>[];
        final pitchSub = player.stream.pitch.listen(pitchEvents.add);

        await player.action.setPitch(1.1);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(pitchEvents, contains(closeTo(1.1, 0.001)));
        expect(player.state.pitch, closeTo(1.1, 0.001));
        await pitchSub.cancel();
      } finally {
        await player.dispose();
      }
    });

    test('Invalid setter values throw on Dart side and never emit on stream', () async {
      final player = MiniaudioPlayer();
      try {
        final volumeEvents = <double>[];
        final volSub = player.stream.volume.listen(volumeEvents.add);

        expect(
          () => player.action.setVolume(-1.0),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => player.action.setVolume(double.nan),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => player.action.setVolume(double.infinity),
          throwsA(isA<ArgumentError>()),
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(volumeEvents, isEmpty);
        await volSub.cancel();
      } finally {
        await player.dispose();
      }
    });
  });

  group('Reactive C Event Dispatcher - Deduplication & Anti-Flooding', () {
    test('Repeated identical setter calls are deduplicated in C and emit once', () async {
      final player = MiniaudioPlayer();
      try {
        await player.action.open(AudioSource.file(sampleWav.path));

        // 1. Volume
        final volumeEvents = <double>[];
        final volSub = player.stream.volume.listen(volumeEvents.add);

        for (int i = 0; i < 10; i++) {
          await player.action.setVolume(0.42);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(volumeEvents.length, equals(1));
        expect(volumeEvents.first, closeTo(0.42, 0.001));
        await volSub.cancel();

        // 2. Balance
        final balanceEvents = <double>[];
        final balSub = player.stream.balance.listen(balanceEvents.add);

        for (int i = 0; i < 10; i++) {
          await player.action.setBalance(-0.3);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(balanceEvents.length, equals(1));
        expect(balanceEvents.first, closeTo(-0.3, 0.001));
        await balSub.cancel();

        // 3. Limiter (default is true, so setting false mutates once and deduplicates)
        final limiterEvents = <bool>[];
        final limSub = player.stream.limiterEnabled.listen(limiterEvents.add);

        for (int i = 0; i < 10; i++) {
          await player.action.setLimiter(false);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(limiterEvents.length, equals(1));
        expect(limiterEvents.first, isFalse);
        await limSub.cancel();

        // 4. Mono
        final monoEvents = <bool>[];
        final monoSub = player.stream.mono.listen(monoEvents.add);

        for (int i = 0; i < 10; i++) {
          await player.action.setMono(true);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(monoEvents.length, equals(1));
        expect(monoEvents.first, isTrue);
        await monoSub.cancel();

        // 5. Crossfeed
        final crossfeedEvents = <CrossfeedMode>[];
        final crossSub = player.stream.crossfeed.listen(crossfeedEvents.add);

        for (int i = 0; i < 10; i++) {
          await player.action.setCrossfeed(CrossfeedMode.moffatBauer);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(crossfeedEvents.length, equals(1));
        expect(crossfeedEvents.first, equals(CrossfeedMode.moffatBauer));
        await crossSub.cancel();

        // 6. Reverb
        final reverbEvents = <Reverb>[];
        final revSub = player.stream.reverb.listen(reverbEvents.add);

        for (int i = 0; i < 10; i++) {
          await player.action.setReverb(Reverb.cathedral);
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(reverbEvents.length, equals(1));
        expect(reverbEvents.first.enabled, isTrue);
        expect(reverbEvents.first.roomSize, closeTo(Reverb.cathedral.roomSize, 0.01));
        await revSub.cancel();
      } finally {
        await player.dispose();
      }
    });

    test('Alternating parameter mutations emit strictly when value actually mutates', () async {
      final player = MiniaudioPlayer();
      try {
        final volumeEvents = <double>[];
        final sub = player.stream.volume.listen(volumeEvents.add);

        // A -> B -> A -> A -> B -> B
        await player.action.setVolume(0.3); // emit 0.3
        await player.action.setVolume(0.7); // emit 0.7
        await player.action.setVolume(0.3); // emit 0.3
        await player.action.setVolume(0.3); // dedup (no emit)
        await player.action.setVolume(0.7); // emit 0.7
        await player.action.setVolume(0.7); // dedup (no emit)

        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(volumeEvents.length, equals(4));
        expect(volumeEvents[0], closeTo(0.3, 0.001));
        expect(volumeEvents[1], closeTo(0.7, 0.001));
        expect(volumeEvents[2], closeTo(0.3, 0.001));
        expect(volumeEvents[3], closeTo(0.7, 0.001));

        await sub.cancel();
      } finally {
        await player.dispose();
      }
    });

    test('Compound DSP parameter deduplication (Preamp, ReplayGain, Equalizer, SilenceConfig)', () async {
      final player = MiniaudioPlayer();
      try {
        await player.action.open(AudioSource.file(sampleWav.path));

        // Preamp
        final preampEvents = <double>[];
        final preSub = player.stream.preamp.listen(preampEvents.add);

        for (int i = 0; i < 5; i++) {
          await player.action.setPreamp(2.5);
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(preampEvents.length, equals(1));
        expect(preampEvents.first, closeTo(2.5, 0.01));
        await preSub.cancel();

        // ReplayGain
        final replayGainEvents = <ReplayGainConfig>[];
        final rgSub = player.stream.replayGain.listen(replayGainEvents.add);

        for (int i = 0; i < 5; i++) {
          await player.action.setReplayGain(gainDb: -6.0, peak: 0.95);
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(replayGainEvents.length, equals(1));
        expect(replayGainEvents.first.gainDb, closeTo(-6.0, 0.01));
        expect(replayGainEvents.first.peak, closeTo(0.95, 0.01));
        await rgSub.cancel();

        // Equalizer
        final eqEvents = <Equalizer>[];
        final eqSub = player.stream.equalizer.listen(eqEvents.add);
        const customEq = Equalizer(
          hz31: 3.0,
          hz63: 2.0,
          hz125: 1.0,
          hz250: 0.0,
          hz500: 0.0,
          hz1k: -1.0,
          hz2k: -2.0,
          hz4k: -3.0,
          hz8k: -2.0,
          hz16k: -1.0,
        );

        for (int i = 0; i < 5; i++) {
          await player.action.setEqualizer(customEq);
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(eqEvents.length, equals(1));
        expect(eqEvents.first.hz31, closeTo(3.0, 0.01));
        await eqSub.cancel();

        // SilenceConfig
        final scEvents = <SilenceSkipConfig>[];
        final scSub = player.stream.silenceConfig.listen(scEvents.add);
        const testSilence = SilenceSkipConfig(
          mode: SilenceSkipMode.continuous,
          thresholdDb: -35.0,
        );

        for (int i = 0; i < 5; i++) {
          await player.action.setSilenceConfig(testSilence);
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(scEvents.length, equals(1));
        expect(scEvents.first.thresholdDb, closeTo(-35.0, 0.01));
        await scSub.cancel();
      } finally {
        await player.dispose();
      }
    });

    test('Visualizer enabled state transitions reactively and deduplicates', () async {
      final player = MiniaudioPlayer();
      try {
        final vizEvents = <bool>[];
        final sub = player.stream.visualizerEnabled.listen(vizEvents.add);

        // Turn on
        await player.action.setVisualizerEnabled(true);
        // Repeat identical
        await player.action.setVisualizerEnabled(true);
        // Turn off
        await player.action.setVisualizerEnabled(false);
        // Repeat identical
        await player.action.setVisualizerEnabled(false);

        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(vizEvents, equals([true, false]));
        await sub.cancel();
      } finally {
        await player.dispose();
      }
    });

    test('100 concurrent unawaited setter mutations resolve cleanly without deadlock', () async {
      final player = MiniaudioPlayer();
      try {
        await player.action.open(AudioSource.file(sampleWav.path));

        final futures = <Future<void>>[];
        for (int i = 0; i < 100; i++) {
          final vol = (i % 20) / 20.0;
          final rate = 0.5 + ((i % 15) / 10.0);
          final pitch = 0.8 + ((i % 10) / 20.0);
          futures.add(player.action.setVolume(vol));
          futures.add(player.action.setRate(rate));
          futures.add(player.action.setPitch(pitch));
        }

        await Future.wait(futures);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(player.state.volume.isNaN, isFalse);
        expect(player.state.rate.isNaN, isFalse);
        expect(player.state.pitch.isNaN, isFalse);
      } finally {
        await player.dispose();
      }
    });

    test('Sequential track transitions dispatch state, duration and position cleanly', () async {
      final wav1Bytes = SyntheticAudioGenerator.generateWavBytes(
        durationSeconds: 0.5,
        frequencyHz: 440.0,
      );
      final wav2Bytes = SyntheticAudioGenerator.generateWavBytes(
        durationSeconds: 1.0,
        frequencyHz: 880.0,
      );

      final player = MiniaudioPlayer();
      try {
        // Track 1
        await player.action.open(AudioSource.memory(wav1Bytes));
        expect(player.state.duration.inMilliseconds, inInclusiveRange(450, 550));
        await player.action.play();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(player.state.playing, isTrue);

        // Track 2 replaces Track 1 mid-playback
        await player.action.open(AudioSource.memory(wav2Bytes));
        expect(player.state.duration.inMilliseconds, inInclusiveRange(950, 1050));
        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.position, equals(Duration.zero));

        await player.action.play();
        expect(player.state.playing, isTrue);
        await player.action.stop();
      } finally {
        await player.dispose();
      }
    });
  });

  group('Reactive C Event Dispatcher - setDevice Future<void> Contract', () {
    test('setDevice returns Future<void> and updates stream.audioDevice', () async {
      final player = MiniaudioPlayer();
      try {
        final deviceEvents = <AudioDevice>[];
        final sub = player.stream.audioDevice.listen(deviceEvents.add);

        // Signature check: must be Future<void>, not Future<bool>
        final Future<void> fut = player.action.setDevice(AudioDevice.auto);
        await fut;

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(player.state.audioDevice.isAuto, isTrue);

        await sub.cancel();
      } finally {
        await player.dispose();
      }
    });
  });

  group('Reactive C Event Dispatcher - Lifecycle & Zero Polling Proof', () {
    test('Zero periodic timers spawned during entire play, pause, seek, stop lifecycle', () async {
      final player = MiniaudioPlayer();
      final List<Timer> timersCreated = [];

      final zoneSpec = ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, period, callback) {
          final t = parent.createPeriodicTimer(zone, period, callback);
          timersCreated.add(t);
          return t;
        },
      );

      await runZoned(() async {
        try {
          await player.action.open(AudioSource.file(sampleWav.path));
          expect(player.state.duration, greaterThan(Duration.zero));

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 150));

          expect(player.state.playing, isTrue);
          expect(player.state.position, greaterThan(Duration.zero));

          await player.action.pause();
          expect(player.state.playing, isFalse);

          await player.action.seek(const Duration(milliseconds: 200));
          expect(player.state.position.inMilliseconds, inInclusiveRange(180, 250));

          await player.action.play();
          await Future<void>.delayed(const Duration(milliseconds: 100));

          await player.action.stop();
          expect(player.state.playing, isFalse);
          expect(player.state.position, equals(Duration.zero));

          expect(timersCreated, isEmpty, reason: 'Zero periodic timers allowed in reactive architecture');
        } finally {
          await player.dispose();
        }
      }, zoneSpecification: zoneSpec);
    });

    test('EOF completion triggers completed state and stream without any polling', () async {
      final shortWavBytes = SyntheticAudioGenerator.generateWavBytes(
        durationSeconds: 0.15,
        frequencyHz: 440.0,
        sampleRate: 44100,
        numChannels: 1,
      );
      final shortFile = File('${tempDir.path}/short_eof.wav');
      await shortFile.writeAsBytes(shortWavBytes, flush: true);

      final player = MiniaudioPlayer();
      try {
        final completedEvents = <bool>[];
        final stateEvents = <PlaybackState>[];

        final cSub = player.stream.completed.listen(completedEvents.add);
        final sSub = player.stream.playbackState.listen(stateEvents.add);

        await player.action.open(AudioSource.file(shortFile.path));
        await player.action.play();

        final stopwatch = Stopwatch()..start();
        while (!player.state.completed && stopwatch.elapsedMilliseconds < 2500) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(player.state.completed, isTrue);
        expect(player.state.playbackState, equals(PlaybackState.completed));
        expect(completedEvents, contains(true));
        expect(stateEvents, contains(PlaybackState.completed));

        await cSub.cancel();
        await sSub.cancel();
      } finally {
        await player.dispose();
        try {
          await shortFile.delete();
        } catch (_) {}
      }
    });

    test('Re-seeking after EOF smoothly resets completed state', () async {
      final shortWavBytes = SyntheticAudioGenerator.generateWavBytes(
        durationSeconds: 0.15,
        frequencyHz: 440.0,
        sampleRate: 44100,
        numChannels: 1,
      );
      final shortFile = File('${tempDir.path}/short_seek_eof.wav');
      await shortFile.writeAsBytes(shortWavBytes, flush: true);

      final player = MiniaudioPlayer();
      try {
        await player.action.open(AudioSource.file(shortFile.path));
        await player.action.play();

        final stopwatch = Stopwatch()..start();
        while (!player.state.completed && stopwatch.elapsedMilliseconds < 2500) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(player.state.completed, isTrue);

        // Seek back to beginning
        await player.action.seek(Duration.zero);
        expect(player.state.completed, isFalse);
        expect(player.state.playbackState, isNot(equals(PlaybackState.completed)));
      } finally {
        await player.dispose();
        try {
          await shortFile.delete();
        } catch (_) {}
      }
    });
  });

  group('Reactive C Event Dispatcher - Error State & Recovery', () {
    test('Non-existent file sets state to error and recovers with openMemory', () async {
      final player = MiniaudioPlayer();
      try {
        final stateEvents = <PlaybackState>[];
        final sub = player.stream.playbackState.listen(stateEvents.add);

        expect(
          () => player.action.open(AudioSource.file('/tmp/this_file_does_not_exist_12345.wav')),
          throwsA(isA<MiniaudioPlayerException>()),
        );

        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(player.state.playbackState, equals(PlaybackState.error));
        expect(stateEvents, contains(PlaybackState.error));

        // Recovery: open valid in-memory audio
        await player.action.open(AudioSource.memory(sampleWavBytes));
        expect(player.state.playbackState, equals(PlaybackState.stopped));
        expect(player.state.duration, greaterThan(Duration.zero));

        // Can play cleanly after recovery
        await player.action.play();
        expect(player.state.playing, isTrue);
        await player.action.stop();

        await sub.cancel();
      } finally {
        await player.dispose();
      }
    });
  });

  group('Reactive C Event Dispatcher - Disposal Safety', () {
    test('Disposed player unbinds native callback safely and actions throw', () async {
      final player = MiniaudioPlayer();
      await player.action.open(AudioSource.memory(sampleWavBytes));
      await player.dispose();

      expect(player.isDisposed, isTrue);

      expect(
        () => player.action.play(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
      expect(
        () => player.action.pause(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
      expect(
        () => player.action.stop(),
        throwsA(isA<MiniaudioPlayerException>()),
      );
      expect(
        () => player.action.seek(Duration.zero),
        throwsA(isA<MiniaudioPlayerException>()),
      );
      expect(
        () => player.action.setVolume(0.5),
        throwsA(isA<MiniaudioPlayerException>()),
      );

      // State getters on disposed player are memory-safe and return cached values
      expect(player.state.duration, greaterThan(Duration.zero));
      expect(player.state.playbackState, isNotNull);
    });
  });
}
