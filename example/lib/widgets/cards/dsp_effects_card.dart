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
    double spacing = 10,
  }) {
    final int columns;
    if (maxColumns >= 4 && maxWidth >= 780) {
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
              // 1. True-Peak Limiter, Mono Downmix & ReplayGain Normalization
              // =============================================================
              LayoutBuilder(
                builder: (context, constraints) {
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

                  final replayGainWidget = _buildReplayGainTile();

                  return _buildResponsiveSubCardGrid(
                    [replayGainWidget, limiterWidget, monoWidget],
                    constraints.maxWidth,
                    maxColumns: 3,
                    twoColumnBreakpoint: 360,
                    spacing: 8,
                  );
                },
              ),
              const SizedBox(height: 10),

              // =============================================================
              // 2. Intelligent Silence Skipping, BS2B Crossfeed, Stereo Widener & Reverb
              // =============================================================
              LayoutBuilder(
                builder: (context, constraints) {
                  return _buildResponsiveSubCardGrid([
                    _buildSmartSilenceSubCard(),
                    BauerCrossfeedSubCard(controller: controller),
                    _buildStereoWidenerSubCard(),
                    ReverbSubCard(controller: controller),
                  ], constraints.maxWidth);
                },
              ),
              const SizedBox(height: 10),

              // =============================================================
              // 4. Preamplifier Gain & Stereo Balance
              // =============================================================
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF070B14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: StudioColors.cardBorder),
                ),
                child: Column(
                  children: [
                    // Preamp Gain Slider
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Text(
                            'Preamp Gain',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${controller.preampDb >= 0 ? "+" : ""}${controller.preampDb.toStringAsFixed(1)} dB',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            color: StudioColors.accentEmerald,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: controller.preampDb.clamp(-12.0, 12.0),
                      min: -12.0,
                      max: 12.0,
                      activeColor: StudioColors.accentEmerald,
                      onChanged: controller.setPreamp,
                    ),
                    const SizedBox(height: 4),

                    // Stereo Balance Slider
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Text(
                            'Stereo Balance / Pan',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          controller.stereoBalance == 0.0
                              ? 'Center'
                              : (controller.stereoBalance < 0
                                    ? 'L ${(controller.stereoBalance.abs() * 100).round()}%'
                                    : 'R ${(controller.stereoBalance * 100).round()}%'),
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            color: StudioColors.accentCyan,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: controller.stereoBalance.clamp(-1.0, 1.0),
                      min: -1.0,
                      max: 1.0,
                      activeColor: StudioColors.accentCyan,
                      onChanged: controller.setStereoBalance,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
