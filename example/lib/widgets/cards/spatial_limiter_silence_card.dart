import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

class SpatialLimiterSilenceCard extends StatelessWidget {
  final AudioEngineController controller;

  const SpatialLimiterSilenceCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return StudioCard(
          icon: Icons.security,
          title: 'SPATIAL PROCESSING, LIMITER & SILENCE',
          subtitle: 'Bauer bs2b Crossfeed • True-Peak Limiter • Dynamic Silence Skipper',
          trailing: const StudioBadge(
            label: 'Pure DSP Pipeline',
            color: StudioColors.accentCyan,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 600;

              final panels = [
                // Panel 1: Binaural Crossfeed
                _buildCrossfeedSubpanel(context),
                // Panel 2: True-Peak Limiter
                _buildLimiterSubpanel(context),
                // Panel 3: Silence Skipping
                _buildSilenceSubpanel(context),
              ];

              if (isCompact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    panels[0],
                    const SizedBox(height: 12),
                    panels[1],
                    const SizedBox(height: 12),
                    panels[2],
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: panels[0]),
                  const SizedBox(width: 10),
                  Expanded(child: panels[1]),
                  const SizedBox(width: 10),
                  Expanded(child: panels[2]),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildCrossfeedSubpanel(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: const Color(0xFF0A0F1D),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: StudioColors.cardBorder, width: 1.0),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.headphones, size: 14, color: StudioColors.accentCyan),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'BINAURAL CROSSFEED',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: StudioColors.accentCyan,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Bauer bs2b Acoustic Model',
            style: TextStyle(fontSize: 8, color: StudioColors.textSecondary),
          ),
          const SizedBox(height: 8),

          // Crossfeed DropdownButtonFormField (required by tests)
          DropdownButtonFormField<CrossfeedMode>(
            initialValue: controller.crossfeedMode,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Modo Crossfeed',
              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            ),
            items: const [
              DropdownMenuItem(
                value: CrossfeedMode.off,
                child: Text('Bypass (Desactivado)', style: TextStyle(fontSize: 9.5)),
              ),
              DropdownMenuItem(
                value: CrossfeedMode.moffatBauer,
                child: Text('Moffat-Bauer (4.5 dB)', style: TextStyle(fontSize: 9.5)),
              ),
              DropdownMenuItem(
                value: CrossfeedMode.chuMoy,
                child: Text('Chu Moy (6.0 dB)', style: TextStyle(fontSize: 9.5)),
              ),
            ],
            onChanged: (mode) {
              if (mode != null) controller.setCrossfeedMode(mode);
            },
          ),
          const SizedBox(height: 8),

          // Spatializer Width
          Text(
            'Stereo Spatializer: Width ${controller.spatializerWidth.toStringAsFixed(2)}x',
            style: const TextStyle(fontSize: 8.5, color: StudioColors.textSecondary),
          ),
          Slider(
            value: controller.spatializerWidth,
            min: 1.0,
            max: 2.0,
            onChanged: (val) => controller.setSpatializerWidth(val),
          ),

          // Stereo Balance
          Text(
            'Balance: ${controller.stereoBalance == 0.0 ? "Center (0.00)" : controller.stereoBalance.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 8.5, color: StudioColors.textSecondary),
          ),
          Slider(
            value: controller.stereoBalance,
            min: -1.0,
            max: 1.0,
            onChanged: (val) => controller.setStereoBalance(val),
          ),

          // Mono downmix
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => controller.setMonoDownmix(!controller.monoDownmix),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: controller.monoDownmix
                    ? StudioColors.accentCyan.withValues(alpha: 0.15)
                    : StudioColors.cardBorder,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(
                      text: 'Mono Downmix: ',
                      style: TextStyle(fontSize: 8.5, color: StudioColors.textSecondary),
                    ),
                    TextSpan(
                      text: controller.monoDownmix ? 'ACTIVE' : 'Bypass',
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        color: controller.monoDownmix
                            ? StudioColors.accentCyan
                            : StudioColors.textMuted,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    ),
  );
  }

  Widget _buildLimiterSubpanel(BuildContext context) {
    final isEnabled = controller.limiterEnabled;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: const Color(0xFF0A0F1D),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: StudioColors.cardBorder, width: 1.0),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.shield, size: 14, color: StudioColors.accentAmber),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'TRUE-PEAK LIMITER',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: StudioColors.accentAmber,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Soft-Knee Brickwall Defense',
            style: TextStyle(fontSize: 8, color: StudioColors.textSecondary),
          ),
          const SizedBox(height: 8),

          // Safeguard active badge (interactive toggle)
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => controller.setLimiterEnabled(!isEnabled),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: isEnabled
                    ? StudioColors.accentAmber.withValues(alpha: 0.15)
                    : StudioColors.cardBorder,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                isEnabled ? 'SAFEGUARD: ACTIVE' : 'SAFEGUARD: BYPASS',
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  color: isEnabled ? StudioColors.accentAmber : StudioColors.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          _buildSpecRow('Linear THD:', '0.00000%'),
          _buildSpecRow('SNR:', '141.4 dB (Transparent)'),
          _buildSpecRow('Ceiling:', '0.996 FS (-0.04 dB)'),
          _buildSpecRow('Overshoot Protection:', '+3.5 dB'),
          const SizedBox(height: 8),

          Center(
            child: Text(
              'Zero Digital Clipping',
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.bold,
                color: isEnabled ? StudioColors.accentAmber : StudioColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    ),
  );
  }

  Widget _buildSilenceSubpanel(BuildContext context) {
    final isEnabled = controller.silenceEnabled;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: const Color(0xFF0A0F1D),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: StudioColors.cardBorder, width: 1.0),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.volume_off, size: 14, color: StudioColors.accentEmerald),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Smart Silence Skipping',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: StudioColors.accentEmerald,
                  ),
                ),
              ),
              Text(
                isEnabled ? 'ON' : 'OFF',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isEnabled ? StudioColors.accentEmerald : StudioColors.textMuted,
                ),
              ),
              Switch(
                value: isEnabled,
                activeThumbColor: StudioColors.accentEmerald,
                onChanged: (val) => controller.setSilenceSkipEnabled(val),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Real-Time Native Detector',
            style: TextStyle(fontSize: 8, color: StudioColors.textSecondary),
          ),
          const SizedBox(height: 8),

          // Sub-controls wrapped in AnimatedOpacity (0.38) and IgnorePointer when OFF
          AnimatedOpacity(
            opacity: isEnabled ? 1.0 : 0.38,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !isEnabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<SilenceSkipMode>(
                    initialValue: controller.silenceMode == SilenceSkipMode.disabled
                        ? SilenceSkipMode.all
                        : controller.silenceMode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Modo de Silencio',
                      contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: SilenceSkipMode.all,
                        child: Text('All (Edges + In-Between Pauses)', style: TextStyle(fontSize: 9.5)),
                      ),
                      DropdownMenuItem(
                        value: SilenceSkipMode.trimEdges,
                        child: Text('Trim Edges (Intro & Outro)', style: TextStyle(fontSize: 9.5)),
                      ),
                      DropdownMenuItem(
                        value: SilenceSkipMode.continuous,
                        child: Text('In-Between Pauses Only', style: TextStyle(fontSize: 9.5)),
                      ),
                    ],
                    onChanged: isEnabled
                        ? (mode) {
                            if (mode != null) controller.setSilenceMode(mode);
                          }
                        : null,
                  ),
                  const SizedBox(height: 6),

                  Text(
                    'Threshold: ${controller.silenceThresholdDb.toStringAsFixed(1)} dBFS',
                    style: const TextStyle(fontSize: 8.5, color: StudioColors.textSecondary),
                  ),
                  Slider(
                    value: controller.silenceThresholdDb,
                    min: -60.0,
                    max: -20.0,
                    onChanged: (val) => controller.setSilenceThresholdDb(val),
                  ),

                  Text(
                    'Min Duration: ${controller.minSilenceDurationMs} ms',
                    style: const TextStyle(fontSize: 8.5, color: StudioColors.textSecondary),
                  ),
                  Slider(
                    value: controller.minSilenceDurationMs.toDouble(),
                    min: 100.0,
                    max: 1000.0,
                    onChanged: (val) => controller.setMinSilenceDurationMs(val.round()),
                  ),

                  // Cumulative Saved Time
                  StreamBuilder<Duration>(
                    stream: controller.engine.stream.silenceSavedDuration,
                    initialData: controller.engine.state.silenceSavedDuration,
                    builder: (context, snapshot) {
                      final savedSec = (snapshot.data?.inMilliseconds ?? 0) / 1000.0;
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Flexible(
                            child: Text(
                              'Cumulative Saved:',
                              style: TextStyle(fontSize: 8.5, color: StudioColors.textSecondary),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '+${savedSec.toStringAsFixed(1)}s',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: StudioColors.accentEmerald,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
  }

  Widget _buildSpecRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Flexible(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(fontSize: 8, color: StudioColors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.bold,
                color: StudioColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
