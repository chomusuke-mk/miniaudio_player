import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/widget_previews.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../models/acoustid_result.dart';
import '../models/audio_track.dart';
import '../theme/studio_colors.dart';
import '../theme/studio_theme.dart';

/// Theme adapter supplying [StudioTheme.darkTheme] to Flutter widget previews.
final class StudioPreviewThemeData extends PreviewThemeData {
  /// Creates a [StudioPreviewThemeData] applying [StudioTheme.darkTheme].
  const StudioPreviewThemeData();

  @override
  Widget apply(BuildContext context, Widget child) {
    return Theme(data: StudioTheme.darkTheme, child: child);
  }
}

/// Top-level preview theme callback consumed by [StudioPreview].
PreviewThemeData studioPreviewTheme() => const StudioPreviewThemeData();

/// Top-level preview wrapper adding the dark studio canvas and comfortable padding
/// around [child] inside Flutter's widget previewer.
Widget studioPreviewWrapper(Widget child) {
  return Material(
    color: StudioColors.bgGradientStart,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    ),
  );
}

/// Shared custom [Preview] annotation preconfigured with the dark studio theme
/// and canvas wrapper for `miniaudio_player` example widgets.
final class StudioPreview extends Preview {
  /// Creates a [StudioPreview] annotation with optional [name], [group], [size],
  /// [textScaleFactor], [brightness], [theme], and [wrapper].
  const StudioPreview({
    super.name,
    super.group = 'Studio',
    super.size,
    super.textScaleFactor,
    super.brightness = Brightness.dark,
    super.theme = studioPreviewTheme,
    super.wrapper = studioPreviewWrapper,
  });
}

/// Shared constant no-op callbacks and Web-safe fixture data used exclusively by
/// `@StudioPreview` functions (zero `dart:io` or `dart:ffi` dependencies).
abstract final class StudioPreviewData {
  /// No-op boolean toggle callback safe for constant widget previews.
  static void noopBool(bool _) {}

  /// No-op scalar slider callback safe for constant widget previews.
  static void noopDouble(double _) {}

  /// No-op void callback safe for constant widget previews.
  static void noopVoid() {}

  /// Sample sinusoidal waveform amplitude curve containing 64 points.
  static List<double> get sampleWaveform => const [
        0.18, 0.34, 0.56, 0.72, 0.49, 0.65, 0.88, 0.92, 0.74, 0.51, 0.38, 0.62,
        0.79, 0.85, 0.67, 0.44, 0.31, 0.54, 0.82, 0.95, 0.77, 0.61, 0.46, 0.28,
        0.36, 0.64, 0.75, 0.58, 0.42, 0.69, 0.87, 0.91, 0.71, 0.52, 0.35, 0.49,
        0.73, 0.84, 0.66, 0.48, 0.29, 0.57, 0.81, 0.89, 0.70, 0.53, 0.39, 0.61,
        0.76, 0.63, 0.45, 0.32, 0.55, 0.78, 0.86, 0.68, 0.50, 0.37, 0.60, 0.74,
        0.59, 0.41, 0.26, 0.19,
      ];

  /// Sample track descriptor used across playback, queue, and analyzer previews.
  static final AudioTrack sampleTrack = AudioTrack(
    id: 'asset://assets/music/01_Apex_Momentum.mp3',
    title: 'Apex Momentum (MP3)',
    source: AudioSource('asset://assets/music/01_Apex_Momentum.mp3'),
    artist: 'Elena Vance • Local Asset',
    album: 'Kinetic Landscapes',
    replayGainDb: -5.75,
    replayPeak: 1.0544,
  );

  /// Secondary remote track descriptor used in queue and inspector previews.
  static final AudioTrack sampleRemoteTrack = AudioTrack(
    id: 'https://example.com/audio/06_Calculated_Motion_aac.m4a',
    title: 'Calculated Motion (Remote M4A AAC)',
    source: AudioSource(
      'https://example.com/audio/06_Calculated_Motion_aac.m4a',
    ),
    artist: 'Kairo Tanaka • Remote Raw CDN',
    album: 'Active State',
  );

  /// Sample hardware output devices for routing matrix previews.
  static const List<AudioDevice> sampleOutputDevices = [
    AudioDevice(
      id: 'AUTO',
      name: 'System Default',
      resolvedName: 'Studio USB-C DAC',
      isAuto: true,
    ),
    AudioDevice(
      id: 'hw_dac_main',
      name: 'Focusrite Scarlett 2i2',
    ),
    AudioDevice(
      id: 'hw_cue_phones',
      name: 'Monitor Headphones (Line Out)',
    ),
  ];

  /// Sample hardware input devices for microphone routing matrix previews.
  static const List<AudioDevice> sampleInputDevices = [
    AudioDevice(
      id: 'AUTO',
      name: 'Default Microphone',
      resolvedName: 'Shure MV7 USB',
      isAuto: true,
    ),
    AudioDevice(
      id: 'mic_usb_podcast',
      name: 'Shure MV7 USB',
    ),
  ];

  /// Sample 10-band visualizer frame displaying balanced bass, mids, and stereo RMS.
  static const VisualizerData sampleVisualizerData = VisualizerData(
    bands: [0.72, 0.85, 0.68, 0.54, 0.62, 0.48, 0.41, 0.56, 0.37, 0.24],
    rms: 0.66,
    peak: 0.82,
    left: 0.68,
    right: 0.64,
  );

  /// Sample probed audio stream metrics for analyzer and metadata previews.
  static final AudioInfo sampleAudioInfo = AudioInfo(
    sampleRate: 48000,
    rawSampleRate: 48000,
    channels: 2,
    bitrate: 320000,
    bitsPerSample: 24,
    format: 'MPEG-1 Layer 3',
    containerFormat: 'MP3 (ID3v2.4)',
    codec: 'mp3',
    bitrateMode: BitrateMode.cbr,
    duration: const Duration(minutes: 3, seconds: 24),
    fileSize: 8342100,
    lossless: false,
  );

  /// Sample ID3/Vorbis metadata record for analyzer and modal previews.
  static final AudioMetadata sampleMetadata = AudioMetadata(
    title: 'Apex Momentum',
    trackArtist: 'Elena Vance',
    album: 'Kinetic Landscapes',
    year: 2025,
    genre: 'Electronic',
    trackNumber: 1,
    trackTotal: 12,
    bpm: 124.0,
    replayGainTrackGain: '-5.75 dB',
    replayGainTrackPeak: '1.054400',
    replayGainAlbumGain: '-6.10 dB',
    replayGainAlbumPeak: '1.089200',
    lyrics: 'Verse 1\nSynthesized waves across midnight skies.',
    chapters: const [
      AudioChapter(
        title: 'Intro Pulse',
        startMs: 0,
        endMs: 42000,
      ),
      AudioChapter(
        title: 'Main Kinetic Drop',
        startMs: 42000,
        endMs: 135000,
      ),
    ],
    customTags: const {'ENCODER': 'LAME 3.100', 'STUDIO_MIX': 'Master Rev B'},
    extended: const ExtendedMetadata(
      isrc: 'USRC17607839',
      label: 'Meridian Audio Labs',
      composer: 'Elena Vance',
      producer: 'Kairo Tanaka',
      initialKey: 'Am',
      releaseDate: '2025-02-14',
      musicBrainzRecordingId: 'a1b2c3d4-0000-4000-8000-000000000001',
    ),
  );

  /// Sample Chromaprint fingerprint payload paired with [sampleAudioInfo].
  static final ChromaprintResult sampleChromaprint = ChromaprintResult(
    fingerprint: 'AQADtMmyJEmSRJEGAAAAQAAAEAAA',
    raw: Uint32List.fromList([0x12345678, 0x9ABCDEF0, 0x0F1E2D3C]),
    algorithm: 2,
  );

  /// Complete sample acoustic analysis payload for analyzer previews.
  static final AudioAnalysisResult sampleAnalysisResult = AudioAnalysisResult(
    audioInfo: sampleAudioInfo,
    replayGain: const ReplayGainResult(
      gainDb: -5.75,
      peak: 1.0544,
      lufs: -12.17,
    ),
    waveform: WaveformResult(points: sampleWaveform),
    metadata: sampleMetadata,
    chromaprint: sampleChromaprint,
  );

  /// Sample AcoustID match result list for lookup dialog body previews.
  static final AcoustIdLookupResult sampleAcoustIdResult =
      AcoustIdLookupResult.success(
        const [
          AcoustIdMatch(
            id: 'acoustid-match-01',
            score: 0.96,
            recordings: [
              AcoustIdRecording(
                id: 'mb-rec-01',
                title: 'Apex Momentum',
                artists: ['Elena Vance'],
                releaseGroups: [
                  AcoustIdReleaseGroup(
                    id: 'mb-rg-01',
                    title: 'Kinetic Landscapes',
                    type: 'Album',
                  ),
                ],
              ),
            ],
          ),
        ],
        isFromCache: true,
      );
}
