import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/compact_slider_overlay.dart';
import '../common/dsp_sub_card.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';
import 'crossfeed_card.dart';

/// Card hosting DSP and spatial mastering processors:
/// - True-Peak Brickwall Limiter
/// - Intelligent Silence Skipping
/// - Bauer BS2B Binaural Crossfeed
/// - Stereo Widener Spatializer
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
            onChanged: controller.setSpatializerWidth,
          ),
        ],
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
              'True-Peak Limiter • Silence Skipper • BS2B Crossfeed • Stereo Widener • Preamp • ReplayGain',
          trailing: const StudioBadge(
            label: 'Mastering Chain',
            color: StudioColors.accentCyan,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // =============================================================
              // 1. True-Peak Limiter & Mono Downmix
              // =============================================================
              LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 360;

                  final limiterWidget = Container(
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
                          Icons.shield_outlined,
                          size: 16,
                          color: controller.limiterEnabled
                              ? StudioColors.accentEmerald
                              : StudioColors.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'True-Peak Limiter',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                controller.limiterEnabled
                                    ? 'Active: 0.0 dBFS ceiling'
                                    : 'Disabled / Bypass',
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
                        Switch(
                          value: controller.limiterEnabled,
                          activeThumbColor: StudioColors.accentEmerald,
                          onChanged: controller.setLimiterEnabled,
                        ),
                      ],
                    ),
                  );

                  final monoWidget = Container(
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
                          Icons.call_merge,
                          size: 16,
                          color: controller.monoDownmix
                              ? StudioColors.accentAmber
                              : StudioColors.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Mono Downmix',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                controller.monoDownmix
                                    ? 'L+R downmixed'
                                    : 'Stereo discrete',
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
                        Switch(
                          value: controller.monoDownmix,
                          activeThumbColor: StudioColors.accentAmber,
                          onChanged: controller.setMonoDownmix,
                        ),
                      ],
                    ),
                  );

                  if (isCompact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        limiterWidget,
                        const SizedBox(height: 8),
                        monoWidget,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: limiterWidget),
                      const SizedBox(width: 8),
                      Expanded(child: monoWidget),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),

              // =============================================================
              // 2. Intelligent Silence Skipping, BS2B Crossfeed & Stereo Widener
              // =============================================================
              LayoutBuilder(
                builder: (context, constraints) {
                  final silenceCard = _buildSmartSilenceSubCard();
                  final crossfeedCard = BauerCrossfeedSubCard(
                    controller: controller,
                  );
                  final widenerCard = _buildStereoWidenerSubCard();

                  if (constraints.maxWidth >= 620) {
                    return IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: silenceCard),
                          const SizedBox(width: 10),
                          Expanded(child: crossfeedCard),
                          const SizedBox(width: 10),
                          Expanded(child: widenerCard),
                        ],
                      ),
                    );
                  }

                  if (constraints.maxWidth >= 420) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: silenceCard),
                              const SizedBox(width: 10),
                              Expanded(child: crossfeedCard),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        widenerCard,
                      ],
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      silenceCard,
                      const SizedBox(height: 10),
                      crossfeedCard,
                      const SizedBox(height: 10),
                      widenerCard,
                    ],
                  );
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
              const SizedBox(height: 10),

              // =============================================================
              // 5. ReplayGain Master Operating Mode
              // =============================================================
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF070B14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: StudioColors.cardBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ReplayGain Normalization',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'Operating Mode: ${controller.replayGainMode.name.toUpperCase()}',
                            style: const TextStyle(
                              fontSize: 9,
                              color: StudioColors.textMuted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<ReplayGainMode>(
                        value: controller.replayGainMode,
                        dropdownColor: const Color(0xFF0E1424),
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
