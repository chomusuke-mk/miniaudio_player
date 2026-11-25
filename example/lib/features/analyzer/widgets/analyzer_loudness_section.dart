import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_metric_tile.dart';

/// Pure sub-section displaying ReplayGain loudness normalization KPIs
/// (compensated gain, true peak, integrated LUFS) and headroom rows.
class AnalyzerLoudnessSection extends StatelessWidget {
  /// Calculated ReplayGain metrics for the inspected track, or `null`.
  final ReplayGainResult? replayGain;

  /// Whether acoustic analysis is currently loading.
  final bool isLoading;

  /// Creates an [AnalyzerLoudnessSection] presenting [replayGain] metrics and
  /// [isLoading] placeholder states.
  const AnalyzerLoudnessSection({
    super.key,
    required this.replayGain,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final rg = replayGain;

    final String gainStr;
    final Color gainColor;
    final String peakStr;
    final Color peakColor;
    final String lufsStr;
    final Color lufsColor;

    if (isLoading) {
      gainStr = 'loading...';
      gainColor = const Color(0xFF64748B);
      peakStr = 'loading...';
      peakColor = const Color(0xFF64748B);
      lufsStr = 'loading...';
      lufsColor = const Color(0xFF64748B);
    } else if (rg != null) {
      gainStr = '${rg.gainDb.toStringAsFixed(1)} dB';
      gainColor = StudioColors.accentPurple;
      peakStr = rg.peak.toStringAsFixed(4);
      peakColor = StudioColors.accentEmerald;
      lufsStr = '${rg.lufs.toStringAsFixed(1)} LUFS';
      lufsColor = StudioColors.accentCyan;
    } else {
      gainStr = '--';
      gainColor = StudioColors.textMuted;
      peakStr = '--';
      peakColor = StudioColors.textMuted;
      lufsStr = '--';
      lufsColor = StudioColors.textMuted;
    }

    final tiles = [
      StudioMetricTile(
        label: 'REPLAY GAIN',
        value: gainStr,
        color: gainColor,
        valueFontSize: 18,
      ),
      StudioMetricTile(
        label: 'TRUE-PEAK',
        value: peakStr,
        color: peakColor,
        valueFontSize: 18,
      ),
      StudioMetricTile(
        label: 'INTEGRATED LOUDNESS',
        value: lufsStr,
        color: lufsColor,
        valueFontSize: 18,
      ),
    ];

    final String peakDbfsStr;
    final String headroomStr;
    final String clipGuardStr;
    if (isLoading) {
      peakDbfsStr = 'loading...';
      headroomStr = 'loading...';
      clipGuardStr = 'loading...';
    } else if (rg != null) {
      if (rg.peak > 0) {
        final dbfs = 20 * math.log(rg.peak) / math.ln10;
        peakDbfsStr = '${dbfs.toStringAsFixed(2)} dBFS';
        headroomStr = rg.peak <= 1.0
            ? '+${(-dbfs).toStringAsFixed(2)} dB'
            : '-${dbfs.toStringAsFixed(2)} dB';
      } else {
        peakDbfsStr = '-inf dBFS';
        headroomStr = 'Full';
      }
      clipGuardStr = rg.peak > 1.0 ? 'Over 0 dBFS' : 'Safe (<= 1.0)';
    } else {
      peakDbfsStr = '--';
      headroomStr = '--';
      clipGuardStr = '--';
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StudioSubCardHeader(
            icon: Icons.tune,
            accentColor: StudioColors.accentPurple,
            title: 'REPLAY GAIN (BS.1770-4 / EBU R128)',
            subtitle:
                'ReplayGain normalizes playback volume to target loudness (-18.0 LUFS). Peak represents true-peak sample headroom to prevent clipping, and Gain specifies the recommended volume compensation offset.',
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  tiles[i],
                ],
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0F1D),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: StudioColors.cardBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Column(
                    children: [
                      StudioPropertyRow(
                        label: 'Target Ref',
                        value: isLoading ? 'loading...' : '-18.0 LUFS',
                        isLoading: isLoading,
                      ),
                      StudioPropertyRow(
                        label: 'Peak dBFS',
                        value: peakDbfsStr,
                        isLoading: isLoading,
                      ),
                      StudioPropertyRow(
                        label: 'Headroom',
                        value: headroomStr,
                        isLoading: isLoading,
                      ),
                      StudioPropertyRow(
                        label: 'Clip Guard',
                        value: clipGuardStr,
                        isLoading: isLoading,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pure sub-section presenting header-probed audio stream and container facts
/// (`AUDIO INFO`) without coupling to controller state.
class AnalyzerAudioInfoSection extends StatelessWidget {
  /// Decoded/probed stream properties, or `null` when unavailable.
  final AudioInfo? audioInfo;

  /// Elapsed duration in milliseconds of the native single-pass decode, if any.
  final int? analysisDurationMs;

  /// Whether the active analysis result came from the session cache.
  final bool servedFromCache;

  /// Whether acoustic analysis is currently running.
  final bool isLoading;

  /// Creates an [AnalyzerAudioInfoSection] rendering [audioInfo] alongside
  /// [analysisDurationMs], [servedFromCache], and [isLoading] status.
  const AnalyzerAudioInfoSection({
    super.key,
    required this.audioInfo,
    this.analysisDurationMs,
    this.servedFromCache = false,
    this.isLoading = false,
  });

  /// Returns `'loading...'` when [isLoading], [value] if non-empty, else `'--'`.
  String _resolveText(String? value, bool isLoading) {
    if (isLoading) return 'loading...';
    if (value == null || value.trim().isEmpty) return '--';
    return value;
  }

  /// Formats [duration] as `MM:SS.t`, returning `'--'` when `null` or zero.
  String _formatDuration(Duration? duration) {
    if (duration == null || duration == Duration.zero) return '--';
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = (duration.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$tenths';
  }

  /// Formats [bytes] into readable `B`, `KB`, or `MB` strings.
  String _formatByteSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '--';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  /// Estimates and comma-formats total PCM sample frames from [info].
  String _formatTotalFrames(AudioInfo? info) {
    if (info == null ||
        info.sampleRate <= 0 ||
        info.duration == null ||
        info.duration! <= Duration.zero) {
      return '--';
    }
    final frames = (info.sampleRate * info.duration!.inMicroseconds / 1000000)
        .round();
    if (frames <= 0) return '--';
    final digits = frames.toString();
    final buf = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buf.write(',');
      }
      buf.write(digits[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final info = audioInfo;
    final String pcmThroughputStr;
    if (isLoading) {
      pcmThroughputStr = 'loading...';
    } else if (info != null && info.sampleRate > 0 && info.channels > 0) {
      final bits = (info.bitsPerSample != null && info.bitsPerSample! > 0)
          ? info.bitsPerSample!
          : 32;
      final kbps = (info.sampleRate * info.channels * bits / 1000).round();
      pcmThroughputStr = '$kbps kbps';
    } else {
      pcmThroughputStr = '--';
    }

    final String analyzeTimeStr;
    if (isLoading) {
      analyzeTimeStr = 'loading...';
    } else if (servedFromCache) {
      analyzeTimeStr = analysisDurationMs != null
          ? '0 ms (cached • ${analysisDurationMs}ms pass)'
          : '0 ms (cache hit)';
    } else if (analysisDurationMs != null) {
      analyzeTimeStr = '$analysisDurationMs ms (1-pass)';
    } else {
      analyzeTimeStr = '--';
    }

    final rows = <(String, String)>[
      (
        'Container Format',
        _resolveText(info?.containerFormat ?? info?.format, isLoading),
      ),
      ('Format', _resolveText(info?.format, isLoading)),
      ('Audio Codec', _resolveText(info?.codec, isLoading)),
      (
        'Sample Rate',
        isLoading
            ? 'loading...'
            : (info != null && info.sampleRate > 0
                  ? '${info.sampleRate} Hz'
                  : '--'),
      ),
      (
        'Raw Sample Rate',
        isLoading
            ? 'loading...'
            : (info?.rawSampleRate != null && info!.rawSampleRate! > 0
                  ? '${info.rawSampleRate} Hz'
                  : '--'),
      ),
      (
        'Channels',
        isLoading
            ? 'loading...'
            : (info != null && info.channels > 0 ? '${info.channels} ch' : '--'),
      ),
      (
        'Bit Depth',
        isLoading
            ? 'loading...'
            : (info?.bitsPerSample != null && info!.bitsPerSample! > 0
                  ? '${info.bitsPerSample}-bit'
                  : '--'),
      ),
      (
        'Bitrate',
        isLoading
            ? 'loading...'
            : (info?.bitrate != null && info!.bitrate > 0
                  ? '${(info.bitrate / 1000).round()} kbps'
                  : '--'),
      ),
      (
        'Bitrate Mode',
        isLoading
            ? 'loading...'
            : (info != null && info.bitrateMode != BitrateMode.unknown
                  ? info.bitrateMode.name.toUpperCase()
                  : '--'),
      ),
      ('Decoded PCM', pcmThroughputStr),
      (
        'Duration',
        isLoading
            ? 'loading...'
            : (info != null && info.duration != Duration.zero
                  ? _formatDuration(info.duration)
                  : '--'),
      ),
      (
        'Total Frames',
        isLoading ? 'loading...' : _formatTotalFrames(info),
      ),
      ('File Size', isLoading ? 'loading...' : _formatByteSize(info?.fileSize)),
      (
        'Lossless',
        isLoading
            ? 'loading...'
            : (info?.lossless == true
                  ? 'Lossless'
                  : (info?.lossless == false ? 'Lossy' : '--')),
      ),
      ('Analysis Pass', analyzeTimeStr),
    ];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StudioSubCardHeader(
            icon: Icons.info_outline,
            accentColor: StudioColors.accentCyan,
            title: 'AUDIO INFO',
            subtitle:
                'Extracted directly from headers at zero decoding cost without affecting playback performance.',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: rows
                  .map(
                    (row) => StudioPropertyRow(
                      label: row.$1,
                      value: row.$2,
                      isLoading: isLoading,
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview rendering [AnalyzerLoudnessSection] with sample BS.1770-4 metrics.
@StudioPreview(
  name: 'Analyzer Loudness Section',
  group: 'Analyzer',
  size: Size(280, 420),
)
Widget analyzerLoudnessSectionPreview() {
  return AnalyzerLoudnessSection(
    replayGain: StudioPreviewData.sampleAnalysisResult.replayGain,
  );
}

/// Preview rendering [AnalyzerAudioInfoSection] with sample container metrics.
@StudioPreview(
  name: 'Analyzer Audio Info Section',
  group: 'Analyzer',
  size: Size(280, 420),
)
Widget analyzerAudioInfoSectionPreview() {
  return AnalyzerAudioInfoSection(
    audioInfo: StudioPreviewData.sampleAudioInfo,
    analysisDurationMs: 420,
    servedFromCache: true,
  );
}
