import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/compact_slider_overlay.dart';

/// Pure responsive transport bar combining track navigation, play/pause,
/// stop, shuffle/loop toggles, and compact volume, varispeed, and pitch pills.
class PlaybackTransportBar extends StatelessWidget {
  /// Current playback engine state (`playing`, `paused`, `stopped`, `loading`).
  final PlaybackState playbackState;

  /// Whether queue shuffle order is active.
  final bool isShuffled;

  /// Active queue repeat mode (`off`, `all`, or `one`).
  final LoopMode loopMode;

  /// Linear playback volume multiplier (`0.0` to `2.0`).
  final double volume;

  /// Playback tempo varispeed factor (`0.25x` to `4.0x`).
  final double rate;

  /// Pitch shift multiplier (`0.5x` to `2.0x`).
  final double pitch;

  /// Invoked when the user taps Previous Track.
  final VoidCallback onPrevious;

  /// Invoked when the user taps Play or Pause.
  final VoidCallback onPlayPause;

  /// Invoked when the user taps Next Track.
  final VoidCallback onNext;

  /// Invoked when the user taps Stop.
  final VoidCallback onStop;

  /// Invoked when the user toggles queue shuffle mode.
  final VoidCallback onToggleShuffle;

  /// Invoked when the user cycles repeat mode.
  final VoidCallback onToggleLoop;

  /// Invoked when the user adjusts master playback volume.
  final ValueChanged<double> onVolumeChanged;

  /// Invoked when the user adjusts playback speed multiplier.
  final ValueChanged<double> onRateChanged;

  /// Invoked when the user adjusts playback pitch multiplier.
  final ValueChanged<double> onPitchChanged;

  /// Creates a [PlaybackTransportBar] reflecting [playbackState], [isShuffled],
  /// [loopMode], [volume], [rate], and [pitch] with transport and DSP control
  /// callbacks.
  const PlaybackTransportBar({
    super.key,
    required this.playbackState,
    required this.isShuffled,
    required this.loopMode,
    required this.volume,
    required this.rate,
    required this.pitch,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onStop,
    required this.onToggleShuffle,
    required this.onToggleLoop,
    required this.onVolumeChanged,
    required this.onRateChanged,
    required this.onPitchChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isPlaying = playbackState == PlaybackState.playing;
    final isLoop = loopMode != LoopMode.off;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 560;

        final leftControls = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, size: 20),
                color: StudioColors.textPrimary,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Previous',
                onPressed: onPrevious,
              ),
              IconButton(
                icon: Icon(
                  isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 32,
                ),
                color: StudioColors.accentCyan,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: isPlaying ? 'Pause' : 'Play',
                onPressed: onPlayPause,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next, size: 20),
                color: StudioColors.textPrimary,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Next',
                onPressed: onNext,
              ),
              IconButton(
                icon: const Icon(Icons.stop, size: 20),
                color: StudioColors.accentRose,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Stop',
                onPressed: onStop,
              ),
              IconButton(
                icon: const Icon(Icons.shuffle, size: 18),
                color: isShuffled
                    ? StudioColors.accentCyan
                    : StudioColors.textMuted,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: isShuffled ? 'Shuffle (On)' : 'Shuffle (Off)',
                onPressed: onToggleShuffle,
              ),
              IconButton(
                icon: Icon(
                  loopMode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                  size: 18,
                ),
                color: isLoop
                    ? StudioColors.accentCyan
                    : StudioColors.textMuted,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Loop Mode: ${loopMode.name.toUpperCase()}',
                onPressed: onToggleLoop,
              ),
            ],
          ),
        );

        final rightControls = Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            CompactSliderControl(
              icon: Icons.volume_up,
              label: 'Vol: ${(volume * 100).round()}%',
              value: volume.clamp(0.0, 2.0),
              defaultValue: 1.0,
              min: 0.0,
              max: 2.0,
              activeColor: StudioColors.accentEmerald,
              valueFormatter: (v) => '${(v * 100).round()}%',
              onChanged: onVolumeChanged,
            ),
            CompactSliderControl(
              icon: Icons.speed,
              label: '${rate.toStringAsFixed(2)}x',
              value: rate,
              defaultValue: 1.0,
              min: 0.25,
              max: 4.0,
              activeColor: StudioColors.accentCyan,
              valueFormatter: (v) => '${v.toStringAsFixed(2)}x',
              onChanged: onRateChanged,
            ),
            CompactSliderControl(
              icon: Icons.tune,
              label: 'Pitch: ${pitch.toStringAsFixed(2)}x',
              value: pitch,
              defaultValue: 1.0,
              min: 0.5,
              max: 2.0,
              activeColor: StudioColors.accentPurple,
              valueFormatter: (v) => '${v.toStringAsFixed(2)}x',
              onChanged: onPitchChanged,
            ),
          ],
        );

        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: leftControls,
              ),
              const SizedBox(height: 6),
              rightControls,
            ],
          );
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: leftControls),
            const SizedBox(width: 8),
            Flexible(child: rightControls),
          ],
        );
      },
    );
  }
}

/// Preview rendering [PlaybackTransportBar] in an active playing state.
@StudioPreview(
  name: 'Playback Transport Bar',
  group: 'Playback',
  size: Size(620, 84),
)
Widget playbackTransportBarPreview() {
  return const PlaybackTransportBar(
    playbackState: PlaybackState.playing,
    isShuffled: true,
    loopMode: LoopMode.all,
    volume: 1.0,
    rate: 1.0,
    pitch: 1.0,
    onPrevious: StudioPreviewData.noopVoid,
    onPlayPause: StudioPreviewData.noopVoid,
    onNext: StudioPreviewData.noopVoid,
    onStop: StudioPreviewData.noopVoid,
    onToggleShuffle: StudioPreviewData.noopVoid,
    onToggleLoop: StudioPreviewData.noopVoid,
    onVolumeChanged: StudioPreviewData.noopDouble,
    onRateChanged: StudioPreviewData.noopDouble,
    onPitchChanged: StudioPreviewData.noopDouble,
  );
}
