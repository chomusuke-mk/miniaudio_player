import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/compact_slider_overlay.dart';
import '../common/dsp_sub_card.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';
import 'algorithmic_reverb_card.dart';
import 'crossfeed_card.dart';
import 'equalizer_card.dart';

/// Card hosting DSP and spatial mastering processors:
/// - True-Peak Brickwall Limiter
/// - Intelligent Silence Skipping
/// - Bauer BS2B Binaural Crossfeed
/// - Stereo Widener Spatializer
/// - Studio Algorithmic Reverb (Freeverb Model)
/// - Master Preamplifier Gain
/// - Stereo Balance / Pan
/// - Monophonic Downmixing
/// - ReplayGain Master Mode
class DspEffectsCard extends StatelessWidget {
  final AudioEngineController controller;

  const DspEffectsCard({super.key, required this.controller});

  String _formatDuration(Duration d) {
    final s = d.inSeconds;
    final ms = d.inMilliseconds.remainder(1000);
    return '$s.${ms ~/ 100}s';
  }

  Widget _buildSmartSilenceSubCard() {
    return DspSubCard(
      icon: Icons.hourglass_empty,
      title: 'Smart Silence Skipping',
      subtitle: controller.silenceEnabled
          ? 'Skipped: ${_formatDuration(controller.silenceSavedDuration)} saved'
          : 'Inactive: plays full timeline without skipping',
      enabled: controller.silenceEnabled,
      accentColor: StudioColors.accentPurple,
      onToggle: controller.setSilenceSkipEnabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<SilenceSkipMode>(
            initialValue: controller.silenceMode,
            isExpanded: true,
            dropdownColor: const Color(0xFF0E1424),
            decoration: const InputDecoration(
              labelText: 'Silence Skip Mode',
              contentPadding: EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
            ),
            items: const [
              DropdownMenuItem(
                value: SilenceSkipMode.all,
                child: Text(
                  'All (Edges + In-Between Pauses)',
                  style: TextStyle(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: SilenceSkipMode.trimEdges,
                child: Text(
                  'Trim Edges (Intro & Outro)',
                  style: TextStyle(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: SilenceSkipMode.continuous,
                child: Text(
                  'Continuous Pauses (Middle Only)',
                  style: TextStyle(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            onChanged: controller.silenceEnabled
                ? (m) {
                    if (m != null) {
                      controller.setSilenceMode(m);
                    }
                  }
                : null,
          ),
          const SizedBox(height: 8),
          CompactSliderControl(
            icon: Icons.graphic_eq,
            label:
                'Threshold: ${controller.silenceThresholdDb.toStringAsFixed(1)} dB',
            value: controller.silenceThresholdDb.clamp(-90.0, -20.0),
            defaultValue: -45.0,
            min: -90.0,
            max: -20.0,
            activeColor: StudioColors.accentPurple,
            disabled: !controller.silenceEnabled,
            valueFormatter: (v) => '${v.toStringAsFixed(1)} dB',
            onChanged: controller.setSilenceThresholdDb,
          ),
        ],
      ),
    );
  }

  Widget _buildStereoWidenerSubCard() {
    return DspSubCard(
      icon: Icons.surround_sound,
      title: 'Stereo Widener',
      subtitle: controller.spatializerEnabled
          ? 'Active: ${controller.spatializerWidth.toStringAsFixed(2)}x Mid/Side spatializer'
          : 'Inactive: standard Mid/Side spatializer field',
      enabled: controller.spatializerEnabled,
      accentColor: StudioColors.accentCyan,
      onToggle: controller.setSpatializerEnabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CompactSliderControl(
            icon: Icons.swap_horiz,
            label: 'Width: ${controller.spatializerWidth.toStringAsFixed(2)}x',
            value: controller.spatializerWidth.clamp(0.0, 2.0),
            defaultValue: 1.0,
            min: 0.0,
            max: 2.0,
            activeColor: StudioColors.accentCyan,
            disabled: !controller.spatializerEnabled,
            valueFormatter: (v) => '${v.toStringAsFixed(2)}x',
            onChanged: controller.setSpatializerWidth,
          ),
        ],
      ),
    );
  }

  Widget _buildResponsiveSubCardGrid(
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

  Widget _buildCompactHeaderTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 8,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: iconColor,
          ),
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

  Widget _buildReplayGainTile() {
    final isActive = controller.replayGainMode != ReplayGainMode.disabled;
    return _buildCompactHeaderTile(
      icon: Icons.equalizer,
      iconColor: isActive ? StudioColors.accentCyan : StudioColors.textMuted,
      title: 'ReplayGain Normalization',
      subtitle:
          'Operating Mode: ${controller.replayGainMode.name.toUpperCase()}',
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF070B14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: StudioColors.cardBorder),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<ReplayGainMode>(
            value: controller.replayGainMode,
            isDense: true,
            icon: const Icon(Icons.arrow_drop_down, size: 16),
            dropdownColor: const Color(0xFF0E172A),
            items: ReplayGainMode.values.map((m) {
              return DropdownMenuItem(
                value: m,
                child: Text(
                  m.name.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            }).toList(),
            onChanged: (mode) {
              if (mode != null) controller.setReplayGainMode(mode);
            },
          ),
        ),
      ),
    );
  }

  static String _formatPreamp(double db) =>
      '${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB';

  static String _formatBalance(double balance) {
    if (balance.abs() < 0.005) return 'Center';
    return balance < 0
        ? 'L ${(balance.abs() * 100).round()}%'
        : 'R ${(balance * 100).round()}%';
  }

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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return StudioCard(
          icon: Icons.tune,
          title: 'DYNAMIC DSP & SPATIAL MASTERING',
          subtitle:
              'True-Peak Limiter • Silence Skipper • BS2B Crossfeed • Stereo Widener • Freeverb Reverb • Preamp • ReplayGain',
          trailing: const StudioBadge(
            label: 'Mastering Chain',
            color: StudioColors.accentCyan,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // =============================================================
              // 1. ReplayGain, Limiter, Mono Downmix, Preamp, Stereo Balance,
              //    Pause on Device Change & Dynamic Metadata Event Stream
              // =============================================================
              LayoutBuilder(
                builder: (context, constraints) {
                  final replayGainWidget = _buildReplayGainTile();

                  final limiterWidget = _buildCompactToggleTile(
                    icon: Icons.shield_outlined,
                    title: 'True-Peak Limiter',
                    subtitle: controller.limiterEnabled
                        ? 'Active: 0.0 dBFS ceiling'
                        : 'Disabled / Bypass',
                    value: controller.limiterEnabled,
                    activeColor: StudioColors.accentEmerald,
                    onChanged: controller.setLimiterEnabled,
                  );

                  final monoWidget = _buildCompactToggleTile(
                    icon: Icons.call_merge,
                    title: 'Mono Downmix',
                    subtitle: controller.monoDownmix
                        ? 'L+R downmixed'
                        : 'Stereo discrete',
                    value: controller.monoDownmix,
                    activeColor: StudioColors.accentAmber,
                    onChanged: controller.setMonoDownmix,
                  );

                  final preampWidget = _buildCompactPillTile(
                    icon: Icons.tune,
                    iconColor: controller.preampDb != 0.0
                        ? StudioColors.accentEmerald
                        : StudioColors.textMuted,
                    title: 'Preamp Gain',
                    subtitle: 'Master stage gain',
                    valueText: _formatPreamp(controller.preampDb),
                    value: controller.preampDb.clamp(-12.0, 12.0),
                    defaultValue: 0.0,
                    min: -12.0,
                    max: 12.0,
                    activeColor: StudioColors.accentEmerald,
                    valueFormatter: _formatPreamp,
                    onChanged: controller.setPreamp,
                  );

                  final balanceWidget = _buildCompactPillTile(
                    icon: Icons.compare_arrows,
                    iconColor: controller.stereoBalance.abs() >= 0.005
                        ? StudioColors.accentCyan
                        : StudioColors.textMuted,
                    title: 'Stereo Balance',
                    subtitle: 'L/R pan field',
                    valueText: _formatBalance(controller.stereoBalance),
                    value: controller.stereoBalance.clamp(-1.0, 1.0),
                    defaultValue: 0.0,
                    min: -1.0,
                    max: 1.0,
                    activeColor: StudioColors.accentCyan,
                    valueFormatter: _formatBalance,
                    onChanged: controller.setStereoBalance,
                  );

                  final pauseOnDeviceWidget = _buildCompactToggleTile(
                    icon: Icons.pause_circle_outline,
                    title: 'Pause on Device Change',
                    subtitle: controller.pauseOnDeviceChange
                        ? 'Immediate native pause (0ms leak) if physical endpoint changes'
                        : 'Inactive: audio switches to new endpoint without pausing',
                    value: controller.pauseOnDeviceChange,
                    activeColor: StudioColors.accentCyan,
                    onChanged: controller.setPauseOnDeviceChange,
                  );

                  final metadataStreamWidget = _buildCompactToggleTile(
                    icon: Icons.tag,
                    title: 'Dynamic Metadata Event Stream',
                    subtitle: controller.metadataEnabled
                        ? 'Active: Rust streams live ID3v2/FLAC/Vorbis metadata events'
                        : 'Disabled: zero channel bus saturation until activated',
                    value: controller.metadataEnabled,
                    activeColor: StudioColors.accentAmber,
                    onChanged: controller.setMetadataEnabled,
                  );

                  return _buildResponsiveSubCardGrid(
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
              ),
              const SizedBox(height: 10),

              // =============================================================
              // 2. Intelligent Silence Skipping, BS2B Crossfeed, Stereo Widener,
              //    Algorithmic Reverb & 10-Band Equalizer
              // =============================================================
              LayoutBuilder(
                builder: (context, constraints) {
                  return _buildSubCardMasteringSection(constraints.maxWidth);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSubCardMasteringSection(double maxWidth) {
    const spacing = 10.0;
    final silence = _buildSmartSilenceSubCard();
    final crossfeed = BauerCrossfeedSubCard(controller: controller);
    final widener = _buildStereoWidenerSubCard();
    final reverb = ReverbSubCard(controller: controller);
    final equalizer = EqualizerSubCard(controller: controller);

    if (maxWidth < 420) {
      return _buildResponsiveSubCardGrid([
        silence,
        crossfeed,
        widener,
        reverb,
        equalizer,
      ], maxWidth, spacing: spacing);
    }

    final isThreeColDrop = maxWidth >= 620 && maxWidth < 780;
    final topGridCards = isThreeColDrop
        ? [silence, crossfeed, widener]
        : [silence, crossfeed, widener, reverb];
    final bottomSection = isThreeColDrop
        ? IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: (maxWidth - spacing * 2) / 3,
                  child: reverb,
                ),
                const SizedBox(width: spacing),
                Expanded(child: equalizer),
              ],
            ),
          )
        : equalizer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildResponsiveSubCardGrid(topGridCards, maxWidth, spacing: spacing),
        const SizedBox(height: spacing),
        bottomSection,
      ],
    );
  }
}
