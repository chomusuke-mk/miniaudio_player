import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/compact_slider_overlay.dart';

/// Pure presentational master bus control strip rendering the 7 compact
/// mastering tiles (ReplayGain, True-Peak Limiter, Mono Downmix, Preamp Gain,
/// Stereo Balance, Pause on Device Change, and Dynamic Metadata Event Stream).
class MasterBusControls extends StatelessWidget {
  /// Active ReplayGain normalization operating mode.
  final ReplayGainMode replayGainMode;

  /// Invoked when the user picks a new [ReplayGainMode].
  final ValueChanged<ReplayGainMode> onReplayGainModeChanged;

  /// Whether the true-peak brickwall limiter is enabled.
  final bool limiterEnabled;

  /// Invoked when the user toggles the true-peak limiter switch.
  final ValueChanged<bool> onLimiterChanged;

  /// Whether stereo channels are downmixed to mono.
  final bool monoDownmix;

  /// Invoked when the user toggles mono downmixing.
  final ValueChanged<bool> onMonoDownmixChanged;

  /// Master preamplifier gain in decibels (`-12.0` to `+12.0` dB).
  final double preampDb;

  /// Invoked when the user adjusts [preampDb].
  final ValueChanged<double> onPreampChanged;

  /// Stereo L/R pan balance (`-1.0` full left to `+1.0` full right).
  final double stereoBalance;

  /// Invoked when the user adjusts [stereoBalance].
  final ValueChanged<double> onStereoBalanceChanged;

  /// Whether playback pauses immediately when the audio endpoint changes.
  final bool pauseOnDeviceChange;

  /// Invoked when the user toggles pause-on-device-change behavior.
  final ValueChanged<bool> onPauseOnDeviceChangeChanged;

  /// Whether live Rust metadata event streaming is enabled.
  final bool metadataEnabled;

  /// Invoked when the user toggles dynamic metadata event streaming.
  final ValueChanged<bool> onMetadataEnabledChanged;

  /// Creates a [MasterBusControls] strip bound to [replayGainMode],
  /// [limiterEnabled], [monoDownmix], [preampDb], [stereoBalance],
  /// [pauseOnDeviceChange], and [metadataEnabled] with their change callbacks.
  const MasterBusControls({
    super.key,
    required this.replayGainMode,
    required this.onReplayGainModeChanged,
    required this.limiterEnabled,
    required this.onLimiterChanged,
    required this.monoDownmix,
    required this.onMonoDownmixChanged,
    required this.preampDb,
    required this.onPreampChanged,
    required this.stereoBalance,
    required this.onStereoBalanceChanged,
    required this.pauseOnDeviceChange,
    required this.onPauseOnDeviceChangeChanged,
    required this.metadataEnabled,
    required this.onMetadataEnabledChanged,
  });

  /// Formats master preamp gain [db] with an explicit sign and `dB` suffix.
  static String formatPreamp(double db) =>
      '${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB';

  /// Formats stereo pan [balance] as `Center`, `L X%`, or `R X%`.
  static String formatBalance(double balance) {
    if (balance.abs() < 0.005) return 'Center';
    return balance < 0
        ? 'L ${(balance.abs() * 100).round()}%'
        : 'R ${(balance * 100).round()}%';
  }

  /// Lays out [cards] in equal-height rows adapting to [maxWidth] using either
  /// [minItemWidth] or fixed breakpoints (`780`, `620`, and
  /// [twoColumnBreakpoint]) up to [maxColumns] with [spacing] gutters.
  static Widget buildResponsiveGrid(
    List<Widget> cards,
    double maxWidth, {
    int maxColumns = 4,
    double twoColumnBreakpoint = 420,
    double? minItemWidth,
    double spacing = 10,
  }) {
    final int columns;
    if (minItemWidth != null) {
      columns = maxColumns <= 1
          ? 1
          : ((maxWidth + spacing) / (minItemWidth + spacing)).floor().clamp(
              1,
              maxColumns,
            );
    } else if (maxColumns == 4 && maxWidth >= 780) {
      columns = 4;
    } else if (maxColumns >= 3 && maxWidth >= 620) {
      columns = 3;
    } else if (maxWidth >= twoColumnBreakpoint) {
      columns = 2;
    } else {
      columns = 1;
    }

    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i += columns) {
      final rowItems = cards.sublist(
        i,
        (i + columns) > cards.length ? cards.length : (i + columns),
      );
      if (rows.isNotEmpty) {
        rows.add(SizedBox(height: spacing));
      }
      if (rowItems.length == 1) {
        rows.add(rowItems.first);
      } else {
        rows.add(
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = 0; j < rowItems.length; j++) ...[
                  if (j > 0) SizedBox(width: spacing),
                  Expanded(child: rowItems[j]),
                ],
              ],
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  /// Builds a compact dark header tile hosting [icon] colored with [iconColor],
  /// [title], [subtitle], and a right-aligned [trailing] control.
  Widget _buildCompactHeaderTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 9,
                    color: StudioColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          trailing,
        ],
      ),
    );
  }

  /// Builds a boolean switch tile with [icon], [title], [subtitle], [value],
  /// [activeColor], and [onChanged].
  Widget _buildCompactToggleTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Color activeColor,
    required ValueChanged<bool> onChanged,
  }) {
    return _buildCompactHeaderTile(
      icon: icon,
      iconColor: value ? activeColor : StudioColors.textMuted,
      title: title,
      subtitle: subtitle,
      trailing: Switch(
        value: value,
        activeThumbColor: activeColor,
        onChanged: onChanged,
      ),
    );
  }

  /// Builds the ReplayGain normalization tile with its mode selector dropdown.
  Widget _buildReplayGainTile() {
    final isActive = replayGainMode != ReplayGainMode.disabled;
    return _buildCompactHeaderTile(
      icon: Icons.equalizer,
      iconColor: isActive ? StudioColors.accentCyan : StudioColors.textMuted,
      title: 'ReplayGain Normalization',
      subtitle: 'Operating Mode: ${replayGainMode.name.toUpperCase()}',
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF070B14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: StudioColors.cardBorder),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<ReplayGainMode>(
            value: replayGainMode,
            isDense: true,
            icon: const Icon(Icons.arrow_drop_down, size: 16),
            dropdownColor: const Color(0xFF0E172A),
            items: ReplayGainMode.values.map((mode) {
              return DropdownMenuItem(
                value: mode,
                child: Text(
                  mode.name.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }).toList(),
            onChanged: (mode) {
              if (mode != null) {
                onReplayGainModeChanged(mode);
              }
            },
          ),
        ),
      ),
    );
  }

  /// Builds a compact scalar pill tile wrapping [CompactSliderControl] with
  /// [icon], [iconColor], [title], [subtitle], [valueText], [value],
  /// [defaultValue], [min], [max], [activeColor], [onChanged], and
  /// [valueFormatter].
  Widget _buildCompactPillTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String valueText,
    required double value,
    required double defaultValue,
    required double min,
    required double max,
    required Color activeColor,
    required ValueChanged<double> onChanged,
    required String Function(double value) valueFormatter,
  }) {
    return _buildCompactHeaderTile(
      icon: icon,
      iconColor: iconColor,
      title: title,
      subtitle: subtitle,
      trailing: CompactSliderControl(
        icon: icon,
        label: valueText,
        value: value,
        defaultValue: defaultValue,
        min: min,
        max: max,
        activeColor: activeColor,
        showTriggerIcon: false,
        valueFormatter: valueFormatter,
        onChanged: onChanged,
      ),
    );
  }

  /// Builds the responsive 7-tile master bus strip.
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final replayGainWidget = _buildReplayGainTile();

        final limiterWidget = _buildCompactToggleTile(
          icon: Icons.shield_outlined,
          title: 'True-Peak Limiter',
          subtitle: limiterEnabled
              ? 'Active: 0.0 dBFS ceiling'
              : 'Disabled / Bypass',
          value: limiterEnabled,
          activeColor: StudioColors.accentEmerald,
          onChanged: onLimiterChanged,
        );

        final monoWidget = _buildCompactToggleTile(
          icon: Icons.call_merge,
          title: 'Mono Downmix',
          subtitle: monoDownmix ? 'L+R downmixed' : 'Stereo discrete',
          value: monoDownmix,
          activeColor: StudioColors.accentAmber,
          onChanged: onMonoDownmixChanged,
        );

        final preampWidget = _buildCompactPillTile(
          icon: Icons.tune,
          iconColor: preampDb != 0.0
              ? StudioColors.accentEmerald
              : StudioColors.textMuted,
          title: 'Preamp Gain',
          subtitle: 'Master stage gain',
          valueText: formatPreamp(preampDb),
          value: preampDb.clamp(-12.0, 12.0),
          defaultValue: 0.0,
          min: -12.0,
          max: 12.0,
          activeColor: StudioColors.accentEmerald,
          valueFormatter: formatPreamp,
          onChanged: onPreampChanged,
        );

        final balanceWidget = _buildCompactPillTile(
          icon: Icons.compare_arrows,
          iconColor: stereoBalance.abs() >= 0.005
              ? StudioColors.accentCyan
              : StudioColors.textMuted,
          title: 'Stereo Balance',
          subtitle: 'L/R pan field',
          valueText: formatBalance(stereoBalance),
          value: stereoBalance.clamp(-1.0, 1.0),
          defaultValue: 0.0,
          min: -1.0,
          max: 1.0,
          activeColor: StudioColors.accentCyan,
          valueFormatter: formatBalance,
          onChanged: onStereoBalanceChanged,
        );

        final pauseOnDeviceWidget = _buildCompactToggleTile(
          icon: Icons.pause_circle_outline,
          title: 'Pause on Device Change',
          subtitle: pauseOnDeviceChange
              ? 'Immediate native pause (0ms leak) if physical endpoint changes'
              : 'Inactive: audio switches to new endpoint without pausing',
          value: pauseOnDeviceChange,
          activeColor: StudioColors.accentCyan,
          onChanged: onPauseOnDeviceChangeChanged,
        );

        final metadataStreamWidget = _buildCompactToggleTile(
          icon: Icons.tag,
          title: 'Dynamic Metadata Event Stream',
          subtitle: metadataEnabled
              ? 'Active: Rust streams live ID3v2/FLAC/Vorbis metadata events'
              : 'Disabled: zero channel bus saturation until activated',
          value: metadataEnabled,
          activeColor: StudioColors.accentAmber,
          onChanged: onMetadataEnabledChanged,
        );

        return buildResponsiveGrid(
          [
            replayGainWidget,
            limiterWidget,
            monoWidget,
            preampWidget,
            balanceWidget,
            pauseOnDeviceWidget,
            metadataStreamWidget,
          ],
          constraints.maxWidth,
          maxColumns: 7,
          minItemWidth: 215.0,
          spacing: 8,
        );
      },
    );
  }
}

/// No-op [ReplayGainMode] callback safe for constant widget previews.
void _noopReplayGainMode(ReplayGainMode _) {}

/// Preview rendering [MasterBusControls] across a 3-column desktop width.
@StudioPreview(
  name: 'Master Bus Controls',
  group: 'DSP',
  size: Size(720, 240),
)
Widget masterBusControlsPreview() {
  return const MasterBusControls(
    replayGainMode: ReplayGainMode.track,
    onReplayGainModeChanged: _noopReplayGainMode,
    limiterEnabled: true,
    onLimiterChanged: StudioPreviewData.noopBool,
    monoDownmix: false,
    onMonoDownmixChanged: StudioPreviewData.noopBool,
    preampDb: 0.0,
    onPreampChanged: StudioPreviewData.noopDouble,
    stereoBalance: 0.0,
    onStereoBalanceChanged: StudioPreviewData.noopDouble,
    pauseOnDeviceChange: true,
    onPauseOnDeviceChangeChanged: StudioPreviewData.noopBool,
    metadataEnabled: true,
    onMetadataEnabledChanged: StudioPreviewData.noopBool,
  );
}
