import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

/// Card hosting remaining DSP effects previously in crossfeed card plus new mastering effects:
/// - True-Peak Brickwall Limiter
/// - Intelligent Silence Skipping
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return StudioCard(
          icon: Icons.tune,
          title: 'DYNAMIC DSP & SPATIAL MASTERING',
          subtitle: 'True-Peak Limiter • Silence Skipper • Stereo Widener • Preamp • ReplayGain',
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
              // 2. Stereo Widener Spatializer
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
                    Row(
                      children: [
                        Icon(
                          Icons.surround_sound,
                          size: 16,
                          color: controller.spatializerEnabled
                              ? StudioColors.accentCyan
                              : StudioColors.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Stereo Widener (Spatializer)',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                controller.spatializerEnabled
                                    ? 'Width factor: ${controller.spatializerWidth.toStringAsFixed(2)}x'
                                    : 'Inactive / Standard Stereo Field',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  color: StudioColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: controller.spatializerEnabled,
                          activeThumbColor: StudioColors.accentCyan,
                          onChanged: controller.setSpatializerEnabled,
                        ),
                      ],
                    ),
                    if (controller.spatializerEnabled) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Flexible(
                            child: Text(
                              'Narrow (0.0x)',
                              style: TextStyle(
                                fontSize: 9,
                                color: StudioColors.textMuted,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${controller.spatializerWidth.toStringAsFixed(2)}x',
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              color: StudioColors.accentCyan,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Flexible(
                            child: Text(
                              'Wide (2.0x)',
                              style: TextStyle(
                                fontSize: 9,
                                color: StudioColors.textMuted,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: controller.spatializerWidth.clamp(0.0, 2.0),
                        min: 0.0,
                        max: 2.0,
                        activeColor: StudioColors.accentCyan,
                        onChanged: controller.setSpatializerWidth,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // =============================================================
              // 3. Intelligent Silence Skipping
              // =============================================================
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF070B14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: StudioColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.hourglass_empty,
                          size: 16,
                          color: controller.silenceEnabled
                              ? StudioColors.accentPurple
                              : StudioColors.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Smart Silence Skipping',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                controller.silenceEnabled
                                    ? 'Skipped: ${_formatDuration(controller.silenceSavedDuration)} saved'
                                    : 'Inactive: plays full timeline without skipping',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  color: StudioColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              controller.silenceEnabled ? 'ON' : 'OFF',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: controller.silenceEnabled
                                    ? StudioColors.accentPurple
                                    : StudioColors.textMuted,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Switch(
                              value: controller.silenceEnabled,
                              activeThumbColor: StudioColors.accentPurple,
                              onChanged: controller.setSilenceSkipEnabled,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    AnimatedOpacity(
                      opacity: controller.silenceEnabled ? 1.0 : 0.38,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !controller.silenceEnabled,
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
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: SilenceSkipMode.trimEdges,
                                  child: Text(
                                    'Trim Edges (Intro & Outro)',
                                    style: TextStyle(fontSize: 10),
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: SilenceSkipMode.continuous,
                                  child: Text(
                                    'Continuous Pauses (Middle Only)',
                                    style: TextStyle(fontSize: 10),
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
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Threshold',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: StudioColors.textMuted,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${controller.silenceThresholdDb.toStringAsFixed(1)} dB',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: StudioColors.accentPurple,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                            Slider(
                              value: controller.silenceThresholdDb.clamp(
                                -90.0,
                                -20.0,
                              ),
                              min: -90.0,
                              max: -20.0,
                              activeColor: StudioColors.accentPurple,
                              onChanged: controller.silenceEnabled
                                  ? controller.setSilenceThresholdDb
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
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
