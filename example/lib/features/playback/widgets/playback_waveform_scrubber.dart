import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/painters/waveform_painter.dart';

/// Pure interactive waveform timeline scrubber displaying played progress,
/// buffered decoder span, elapsed timestamp, and total duration or `LIVE`.
class PlaybackWaveformScrubber extends StatelessWidget {
  /// Normalized amplitude envelope rendered across the scrubber bar.
  final List<double> waveformPoints;

  /// Current playback timeline position.
  final Duration position;

  /// Total track duration, or `null` for unbounded live radio/ICY streams.
  final Duration? duration;

  /// Active buffer coverage span highlighted behind the waveform bars.
  final Buffer buffer;

  /// Invoked with a normalized seek fraction in `[0.0, 1.0]` on tap or drag.
  final ValueChanged<double> onSeekFraction;

  /// Creates a [PlaybackWaveformScrubber] rendering [waveformPoints] with
  /// [position], optional [duration], [buffer] coverage, and [onSeekFraction].
  const PlaybackWaveformScrubber({
    super.key,
    required this.waveformPoints,
    required this.position,
    required this.duration,
    required this.buffer,
    required this.onSeekFraction,
  });

  /// Formats [d] as `MM:SS.t` for timeline counters.
  static String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$tenths';
  }

  /// Dispatches a clamped normalized seek offset for [localDx] within [width].
  void _dispatchSeek(double localDx, double width) {
    if (duration == null || duration!.inMilliseconds <= 0 || width <= 0) {
      return;
    }
    onSeekFraction((localDx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final dur = duration;
    final hasDur = dur != null && dur.inMilliseconds > 0;
    final progress = hasDur
        ? (position.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final bufferStartProgress = hasDur
        ? (buffer.start.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final bufferedProgress = hasDur
        ? (buffer.end.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) =>
                  _dispatchSeek(details.localPosition.dx, constraints.maxWidth),
              onHorizontalDragStart: (details) =>
                  _dispatchSeek(details.localPosition.dx, constraints.maxWidth),
              onHorizontalDragUpdate: (details) =>
                  _dispatchSeek(details.localPosition.dx, constraints.maxWidth),
              child: Container(
                height: 44,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF070B14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: StudioColors.cardBorder,
                    width: 1.0,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, 44),
                      painter: WaveformPainter(
                        points: waveformPoints,
                        progress: progress,
                        bufferStartProgress: bufferStartProgress,
                        bufferedProgress: bufferedProgress,
                        playedColor: StudioColors.accentCyan,
                        unplayedColor: StudioColors.cardBorderFocused,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                _formatDuration(position),
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: StudioColors.accentCyan,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Flexible(
              child: Text(
                dur != null ? _formatDuration(dur) : 'LIVE',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: StudioColors.textSecondary,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Preview rendering [PlaybackWaveformScrubber] midway through a buffered track.
@StudioPreview(
  name: 'Waveform Seek Scrubber',
  group: 'Playback',
  size: Size(560, 96),
)
Widget playbackWaveformScrubberPreview() {
  return PlaybackWaveformScrubber(
    waveformPoints: StudioPreviewData.sampleWaveform,
    position: const Duration(minutes: 1, seconds: 18),
    duration: const Duration(minutes: 3, seconds: 24),
    buffer: const Buffer(
      start: Duration(seconds: 20),
      end: Duration(minutes: 2, seconds: 45),
      isBuffering: false,
    ),
    onSeekFraction: StudioPreviewData.noopDouble,
  );
}
