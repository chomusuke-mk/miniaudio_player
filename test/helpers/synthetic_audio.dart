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
