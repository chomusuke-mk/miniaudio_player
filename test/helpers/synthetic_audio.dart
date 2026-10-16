import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Pure Dart procedural generator for 16-bit PCM RIFF WAV audio.
///
/// Enables zero-dependency offline automated testing without committing
/// binary media assets into the codebase.
class SyntheticAudioGenerator {
  /// Generates a byte buffer containing a valid 16-bit PCM RIFF WAV file.
  ///
  /// - [frequencyHz]: Sine wave frequency in Hertz (default: 440.0 Hz).
  /// - [durationSeconds]: Playback length in seconds (default: 1.0 s).
  /// - [sampleRate]: Sampling frequency in Hz (default: 44,100 Hz).
  /// - [numChannels]: Audio channels: 1 for mono, 2 for stereo (default: 1).
  /// - [amplitude]: Normalized peak amplitude between 0.0 and 1.0 (default: 0.8).
  /// - [stereoRightFrequencyHz]: Optional frequency for channel 2 when [numChannels] is 2.
  static Uint8List generateWavBytes({
    double frequencyHz = 440.0,
    double durationSeconds = 1.0,
    int sampleRate = 44100,
    int numChannels = 1,
    double amplitude = 0.8,
    double? stereoRightFrequencyHz,
  }) {
    if (numChannels < 1 || numChannels > 2) {
      throw ArgumentError.value(
        numChannels,
        'numChannels',
        'Only 1 (mono) or 2 (stereo) channels supported',
      );
    }
    if (durationSeconds < 0.0) {
      throw ArgumentError.value(
        durationSeconds,
        'durationSeconds',
        'Duration must be non-negative',
      );
    }
    if (sampleRate <= 0) {
      throw ArgumentError.value(
        sampleRate,
        'sampleRate',
        'Sample rate must be positive',
      );
    }

    final int numSamples = (durationSeconds * sampleRate).toInt();
    const int bitsPerSample = 16;
    const int bytesPerSample = bitsPerSample ~/ 8;
    final int subChunk2Size = numSamples * numChannels * bytesPerSample;
    final int chunkSize = 36 + subChunk2Size;
    final int byteRate = sampleRate * numChannels * bytesPerSample;
    final int blockAlign = numChannels * bytesPerSample;

    final ByteData byteData = ByteData(44 + subChunk2Size);

    // 1. RIFF Header Chunk
    byteData.setUint8(0, 0x52); // 'R'
    byteData.setUint8(1, 0x49); // 'I'
    byteData.setUint8(2, 0x46); // 'F'
    byteData.setUint8(3, 0x46); // 'F'
    byteData.setUint32(4, chunkSize, Endian.little);
    byteData.setUint8(8, 0x57); // 'W'
    byteData.setUint8(9, 0x41); // 'A'
    byteData.setUint8(10, 0x56); // 'V'
    byteData.setUint8(11, 0x45); // 'E'

    // 2. fmt Sub-chunk
    byteData.setUint8(12, 0x66); // 'f'
    byteData.setUint8(13, 0x6D); // 'm'
    byteData.setUint8(14, 0x74); // 't'
    byteData.setUint8(15, 0x20); // ' '
    byteData.setUint32(16, 16, Endian.little); // Subchunk1Size = 16 for PCM
    byteData.setUint16(20, 1, Endian.little); // AudioFormat = 1 (Linear PCM)
    byteData.setUint16(22, numChannels, Endian.little);
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, byteRate, Endian.little);
    byteData.setUint16(32, blockAlign, Endian.little);
    byteData.setUint16(34, bitsPerSample, Endian.little);

    // 3. data Sub-chunk
    byteData.setUint8(36, 0x64); // 'd'
    byteData.setUint8(37, 0x61); // 'a'
    byteData.setUint8(38, 0x74); // 't'
    byteData.setUint8(39, 0x61); // 'a'
    byteData.setUint32(40, subChunk2Size, Endian.little);

    // 4. PCM Waveform Synthesis
    int offset = 44;
    final double clampedAmp = amplitude.clamp(0.0, 1.0);
    final double peakVal = 32767.0 * clampedAmp;

    final double angularFreqLeft = 2.0 * pi * frequencyHz / sampleRate;
    final double rightFreq = stereoRightFrequencyHz ?? frequencyHz;
    final double angularFreqRight = 2.0 * pi * rightFreq / sampleRate;

    for (int i = 0; i < numSamples; i++) {
      // Left / Mono sample
      final double sampleLeft = sin(angularFreqLeft * i);
      final int intLeft = (sampleLeft * peakVal).round().clamp(-32768, 32767);
      byteData.setInt16(offset, intLeft, Endian.little);
      offset += 2;

      // Right sample if stereo
      if (numChannels == 2) {
        final double sampleRight = sin(angularFreqRight * i);
        final int intRight = (sampleRight * peakVal).round().clamp(
          -32768,
          32767,
        );
        byteData.setInt16(offset, intRight, Endian.little);
        offset += 2;
      }
    }

    return byteData.buffer.asUint8List();
  }

  /// Generates silence audio bytes (amplitude 0) of given duration.
  static Uint8List generateSilenceBytes({
    double durationSeconds = 1.0,
    int sampleRate = 44100,
    int numChannels = 1,
  }) {
    return generateWavBytes(
      frequencyHz: 0.0,
      durationSeconds: durationSeconds,
      sampleRate: sampleRate,
      numChannels: numChannels,
      amplitude: 0.0,
    );
  }

  /// Creates a temporary WAV file on disk and returns its [File] handle.
  static Future<File> createTempWavFile({
    String fileName = 'synthetic_tone.wav',
    double frequencyHz = 440.0,
    double durationSeconds = 1.0,
    int sampleRate = 44100,
    int numChannels = 1,
    double amplitude = 0.8,
    double? stereoRightFrequencyHz,
  }) async {
    final bytes = generateWavBytes(
      frequencyHz: frequencyHz,
      durationSeconds: durationSeconds,
      sampleRate: sampleRate,
      numChannels: numChannels,
      amplitude: amplitude,
      stereoRightFrequencyHz: stereoRightFrequencyHz,
    );
    final tempDir = await Directory.systemTemp.createTemp('miniaudio_test_');
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Creates a temporary silent WAV file on disk.
  static Future<File> createTempSilenceWavFile({
    String fileName = 'synthetic_silence.wav',
    double durationSeconds = 1.0,
    int sampleRate = 44100,
    int numChannels = 1,
  }) async {
    return createTempWavFile(
      fileName: fileName,
      frequencyHz: 0.0,
      durationSeconds: durationSeconds,
      sampleRate: sampleRate,
      numChannels: numChannels,
      amplitude: 0.0,
    );
  }

  /// Generates a WAV file composed of multiple sequential audio segments.
  static Uint8List generateMultiSegmentWavBytes({
    required List<({double durationSeconds, double frequencyHz, double amplitude})>
        segments,
    int sampleRate = 44100,
    int numChannels = 1,
  }) {
    double totalDuration = 0.0;
    for (final seg in segments) {
      totalDuration += seg.durationSeconds;
    }
    final int totalSamples = (totalDuration * sampleRate).toInt();
    const int bitsPerSample = 16;
    const int bytesPerSample = bitsPerSample ~/ 8;
    final int subChunk2Size = totalSamples * numChannels * bytesPerSample;
    final int chunkSize = 36 + subChunk2Size;
    final int byteRate = sampleRate * numChannels * bytesPerSample;
    final int blockAlign = numChannels * bytesPerSample;

    final ByteData byteData = ByteData(44 + subChunk2Size);

    // RIFF Header Chunk
    byteData.setUint8(0, 0x52); // 'R'
    byteData.setUint8(1, 0x49); // 'I'
    byteData.setUint8(2, 0x46); // 'F'
    byteData.setUint8(3, 0x46); // 'F'
    byteData.setUint32(4, chunkSize, Endian.little);
    byteData.setUint8(8, 0x57); // 'W'
    byteData.setUint8(9, 0x41); // 'A'
    byteData.setUint8(10, 0x56); // 'V'
    byteData.setUint8(11, 0x45); // 'E'

    // fmt Sub-chunk
    byteData.setUint8(12, 0x66); // 'f'
    byteData.setUint8(13, 0x6D); // 'm'
    byteData.setUint8(14, 0x74); // 't'
    byteData.setUint8(15, 0x20); // ' '
    byteData.setUint32(16, 16, Endian.little);
    byteData.setUint16(20, 1, Endian.little);
    byteData.setUint16(22, numChannels, Endian.little);
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, byteRate, Endian.little);
    byteData.setUint16(32, blockAlign, Endian.little);
    byteData.setUint16(34, bitsPerSample, Endian.little);

    // data Sub-chunk
    byteData.setUint8(36, 0x64); // 'd'
    byteData.setUint8(37, 0x61); // 'a'
    byteData.setUint8(38, 0x74); // 't'
    byteData.setUint8(39, 0x61); // 'a'
    byteData.setUint32(40, subChunk2Size, Endian.little);

    int offset = 44;
    for (final seg in segments) {
      final int segSamples = (seg.durationSeconds * sampleRate).toInt();
      final double peakVal = 32767.0 * seg.amplitude.clamp(0.0, 1.0);
      final double angularFreq = 2.0 * pi * seg.frequencyHz / sampleRate;

      for (int i = 0; i < segSamples; i++) {
        final double sample = (seg.frequencyHz == 0.0 || seg.amplitude == 0.0)
            ? 0.0
            : sin(angularFreq * i);
        final int intVal = (sample * peakVal).round().clamp(-32768, 32767);
        for (int ch = 0; ch < numChannels; ch++) {
          byteData.setInt16(offset, intVal, Endian.little);
          offset += 2;
        }
      }
    }

    return byteData.buffer.asUint8List();
  }

  /// Creates a temporary multi-segment WAV file on disk.
  static Future<File> createTempMultiSegmentWavFile({
    String fileName = 'multi_segment.wav',
    required List<({double durationSeconds, double frequencyHz, double amplitude})>
        segments,
    int sampleRate = 44100,
    int numChannels = 1,
  }) async {
    final bytes = generateMultiSegmentWavBytes(
      segments: segments,
      sampleRate: sampleRate,
      numChannels: numChannels,
    );
    final tempDir =
        await Directory.systemTemp.createTemp('miniaudio_multiseg_');
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Creates a corrupted or truncated file to test parser/decoder resilience.
  static Future<File> createCorruptedFile({
    String fileName = 'corrupted.wav',
    int byteLength = 20,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'miniaudio_corrupted_',
    );
    final file = File('${tempDir.path}/$fileName');
    final random = Random(42);
    final bytes = Uint8List.fromList(
      List.generate(byteLength, (_) => random.nextInt(256)),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Creates an empty (0-byte) file to test boundary handling.
  static Future<File> createZeroByteFile({
    String fileName = 'empty.wav',
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('miniaudio_empty_');
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(Uint8List(0), flush: true);
    return file;
  }

  /// Deletes a file and its temporary parent folder safely.
  static Future<void> cleanUp(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) {
        final parentDir = file.parent;
        await file.delete();
        if (await parentDir.exists()) {
          await parentDir.delete(recursive: true);
        }
      }
    } catch (_) {
      // Ignore cleanup failures in test teardown
    }
  }

  /// Validates whether a given buffer is a compliant 16-bit PCM RIFF WAV format.
  static bool isValidWav(Uint8List bytes) {
    if (bytes.length < 44) return false;
    final ByteData bd = ByteData.sublistView(bytes);

    // 'RIFF' header
    final isRiff =
        bd.getUint8(0) == 0x52 &&
        bd.getUint8(1) == 0x49 &&
        bd.getUint8(2) == 0x46 &&
        bd.getUint8(3) == 0x46;
    if (!isRiff) return false;

    // 'WAVE' header
    final isWave =
        bd.getUint8(8) == 0x57 &&
        bd.getUint8(9) == 0x41 &&
        bd.getUint8(10) == 0x56 &&
        bd.getUint8(11) == 0x45;
    if (!isWave) return false;

    // 'fmt ' marker
    final isFmt =
        bd.getUint8(12) == 0x66 &&
        bd.getUint8(13) == 0x6D &&
        bd.getUint8(14) == 0x74 &&
        bd.getUint8(15) == 0x20;
    if (!isFmt) return false;

    final format = bd.getUint16(20, Endian.little);
    if (format != 1) return false; // 1 = PCM

    final bitsPerSample = bd.getUint16(34, Endian.little);
    if (bitsPerSample != 16) return false;

    // 'data' marker
    final isData =
        bd.getUint8(36) == 0x64 &&
        bd.getUint8(37) == 0x61 &&
        bd.getUint8(38) == 0x74 &&
        bd.getUint8(39) == 0x61;
    if (!isData) return false;

    final subChunk2Size = bd.getUint32(40, Endian.little);
    return bytes.length == (44 + subChunk2Size);
  }

  /// Injects corrupted random bytes into a valid WAV byte buffer mid-stream
  /// while preserving the 44-byte RIFF header.
  static Uint8List corruptWav(
    Uint8List original, {
    int? corruptionOffset,
    int? corruptionLength,
    int seed = 42,
  }) {
    if (original.length < 44) {
      throw ArgumentError.value(
        original.length,
        'original',
        'WAV buffer must be at least 44 bytes to preserve RIFF header',
      );
    }
    final result = Uint8List.fromList(original);
    final int safeOffset = corruptionOffset ?? (44 + (original.length - 44) ~/ 2);
    final int clampedOffset = safeOffset.clamp(44, original.length);
    final int safeLength = corruptionLength ?? min(2048, original.length - clampedOffset);
    final int effectiveLength = min(safeLength, original.length - clampedOffset);

    final random = Random(seed);
    for (int i = 0; i < effectiveLength; i++) {
      result[clampedOffset + i] = random.nextInt(256);
    }
    return result;
  }

  /// Procedurally generates a valid WAV file with corrupted mid-stream audio frames.
  static Uint8List generateWavWithCorruptFrames({
    int sampleRate = 44100,
    int channels = 1,
    Duration duration = const Duration(seconds: 2),
    double corruptAtRatio = 0.5,
    int corruptLengthBytes = 2048,
    int seed = 42,
  }) {
    final cleanBytes = generateWavBytes(
      durationSeconds: duration.inMicroseconds / 1000000.0,
      sampleRate: sampleRate,
      numChannels: channels,
    );
    final dataLength = cleanBytes.length - 44;
    final blockAlign = channels * 2;
    final rawOffset = 44 + (dataLength * corruptAtRatio.clamp(0.0, 1.0)).toInt();
    final alignedOffset = (rawOffset ~/ blockAlign) * blockAlign;

    return corruptWav(
      cleanBytes,
      corruptionOffset: alignedOffset,
      corruptionLength: corruptLengthBytes,
      seed: seed,
    );
  }

  /// Injects bit-flips across arbitrary audio byte buffers (MP3, FLAC, OGG, WAV, etc.)
  /// while preserving headers up to [startOffset].
  static Uint8List injectBitFlips(
    Uint8List data, {
    double flipProbability = 0.001,
    int startOffset = 0,
    int? endOffset,
    int seed = 42,
  }) {
    final result = Uint8List.fromList(data);
    final int effectiveStart = startOffset.clamp(0, data.length);
    final int effectiveEnd = (endOffset ?? data.length).clamp(effectiveStart, data.length);

    if (effectiveEnd <= effectiveStart) return result;

    final random = Random(seed);
    int flipsApplied = 0;

    for (int i = effectiveStart; i < effectiveEnd; i++) {
      if (random.nextDouble() < flipProbability) {
        final bitMask = 1 << random.nextInt(8);
        result[i] ^= bitMask;
        flipsApplied++;
      }
    }

    // Guarantee at least 1 bit flip if range is non-empty
    if (flipsApplied == 0 && effectiveEnd > effectiveStart) {
      final targetIdx = effectiveStart + random.nextInt(effectiveEnd - effectiveStart);
      result[targetIdx] ^= (1 << random.nextInt(8));
    }

    return result;
  }

  /// Generates a valid WAV with corrupted chunk sizes (claims 10 MB, actual file is 100 KB).
  static Uint8List generateWavWithCorruptHeaderChunkLength({
    int sampleRate = 44100,
    int channels = 1,
    Duration duration = const Duration(milliseconds: 500),
    int fakeChunkSize = 10485796, // 10 MB + 36
    int fakeDataSize = 10485760,  // 10 MB
  }) {
    final bytes = generateWavBytes(
      durationSeconds: duration.inMicroseconds / 1000000.0,
      sampleRate: sampleRate,
      numChannels: channels,
    );
    final result = Uint8List.fromList(bytes);
    final byteData = ByteData.sublistView(result);
    // Overwrite RIFF ChunkSize (bytes 4..7)
    byteData.setUint32(4, fakeChunkSize, Endian.little);
    // Overwrite data SubChunk2Size (bytes 40..43)
    byteData.setUint32(40, fakeDataSize, Endian.little);
    return result;
  }

  /// Generates a 32-bit floating-point WAV containing IEEE 754 NaN, Infinity, and Denormals.
  static Uint8List generateFloat32WavWithNaN({
    int sampleRate = 44100,
    int channels = 1,
    Duration duration = const Duration(seconds: 1),
    bool injectInfinity = true,
    bool injectDenormals = true,
  }) {
    final int numSamples = (duration.inMicroseconds / 1000000.0 * sampleRate).toInt();
    const int bitsPerSample = 32;
    const int bytesPerSample = 4;
    final int subChunk2Size = numSamples * channels * bytesPerSample;
    final int chunkSize = 36 + subChunk2Size;
    final int byteRate = sampleRate * channels * bytesPerSample;
    final int blockAlign = channels * bytesPerSample;

    final ByteData byteData = ByteData(44 + subChunk2Size);

    // RIFF Header
    byteData.setUint8(0, 0x52); byteData.setUint8(1, 0x49);
    byteData.setUint8(2, 0x46); byteData.setUint8(3, 0x46);
    byteData.setUint32(4, chunkSize, Endian.little);
    byteData.setUint8(8, 0x57); byteData.setUint8(9, 0x41);
    byteData.setUint8(10, 0x56); byteData.setUint8(11, 0x45);

    // fmt Subchunk (AudioFormat = 3: IEEE Float)
    byteData.setUint8(12, 0x66); byteData.setUint8(13, 0x6D);
    byteData.setUint8(14, 0x74); byteData.setUint8(15, 0x20);
    byteData.setUint32(16, 16, Endian.little);
    byteData.setUint16(20, 3, Endian.little); // 3 = IEEE Float
    byteData.setUint16(22, channels, Endian.little);
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, byteRate, Endian.little);
    byteData.setUint16(32, blockAlign, Endian.little);
    byteData.setUint16(34, bitsPerSample, Endian.little);

    // data Subchunk
    byteData.setUint8(36, 0x64); byteData.setUint8(37, 0x61);
    byteData.setUint8(38, 0x74); byteData.setUint8(39, 0x61);
    byteData.setUint32(40, subChunk2Size, Endian.little);

    int offset = 44;
    for (int i = 0; i < numSamples; i++) {
      final double sample = sin(2.0 * pi * 440.0 * i / sampleRate) * 0.5;
      // Inject NaN at 25%
      if (i == (numSamples * 0.25).toInt()) {
        byteData.setUint32(offset, 0x7FC00000, Endian.little); // Quiet NaN
      } else if (injectInfinity && i == (numSamples * 0.5).toInt()) {
        byteData.setUint32(offset, 0x7F800000, Endian.little); // +Infinity
      } else if (injectDenormals && i == (numSamples * 0.75).toInt()) {
        byteData.setUint32(offset, 0x00000001, Endian.little); // Smallest subnormal
      } else {
        byteData.setFloat32(offset, sample, Endian.little);
      }
      offset += 4;
    }
    return byteData.buffer.asUint8List();
  }

  /// Creates a temporary WAV file containing corrupted mid-stream audio frames.
  static Future<File> createTempCorruptedWavFile({
    String fileName = 'corrupted_midstream.wav',
    Duration duration = const Duration(seconds: 2),
    double corruptAtRatio = 0.5,
    int corruptLengthBytes = 2048,
  }) async {
    final bytes = generateWavWithCorruptFrames(
      duration: duration,
      corruptAtRatio: corruptAtRatio,
      corruptLengthBytes: corruptLengthBytes,
    );
    final tempDir = await Directory.systemTemp.createTemp('miniaudio_corrupt_');
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Creates a temporary file with injected bit-flips across arbitrary audio bytes.
  static Future<File> createTempBitFlippedFile({
    required Uint8List sourceBytes,
    String fileName = 'bit_flipped.audio',
    double flipProbability = 0.001,
    int startOffset = 512,
    int seed = 42,
  }) async {
    final bytes = injectBitFlips(
      sourceBytes,
      flipProbability: flipProbability,
      startOffset: startOffset,
      seed: seed,
    );
    final tempDir = await Directory.systemTemp.createTemp('miniaudio_bitflip_');
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Parses duration from valid RIFF WAV bytes.
  static Duration parseWavDuration(Uint8List bytes) {
    if (!isValidWav(bytes)) {
      throw const FormatException('Not a valid 16-bit PCM WAV file');
    }
    final ByteData bd = ByteData.sublistView(bytes);
    final int byteRate = bd.getUint32(28, Endian.little);
    final int dataSize = bd.getUint32(40, Endian.little);
    final double seconds = dataSize / byteRate;
    return Duration(microseconds: (seconds * 1000000).round());
  }
}

/// Typedef alias for contract compliance.
typedef SyntheticAudio = SyntheticAudioGenerator;

