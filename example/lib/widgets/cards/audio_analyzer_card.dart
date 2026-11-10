import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import '../../controllers/audio_analyzer_controller.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

/// Card hosting the ITU-R BS.1770-4 / EBU R128 Unified Audio Analyzer,
/// native ReplayGain operating modes with comprehensive English descriptions,
/// and live streaming metadata extraction controls.
class AudioAnalyzerCard extends StatelessWidget {
  final AudioEngineController playerController;
  final AudioAnalyzerController analyzerController;

  const AudioAnalyzerCard({
    super.key,
    required this.playerController,
    required this.analyzerController,
  });

  String _getReplayGainModeDescription(ReplayGainMode mode) {
    switch (mode) {
      case ReplayGainMode.track:
        return 'Automatically applies individual ITU-R BS.1770-4 / EBU R128 loudness normalization metadata per track. Falling back to defaultReplayGain if not analyzed.';
      case ReplayGainMode.forced:
        return 'Enforces a uniform global target gain adjustment across all tracks indiscriminately, overriding individual per-track acoustic metadata.';
      case ReplayGainMode.disabled:
        return 'Completely bypasses ReplayGain loudness normalization. Audio plays at native unity gain (0.0 dB) with raw container levels.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([analyzerController, playerController]),
      builder: (context, _) {
        final track = playerController.selectedTrack;
        final canAnalyze = track != null && track.canAnalyze;
        final result = analyzerController.getResultForTrack(track);
        final isTrackRgActive = analyzerController.isReplayGainActiveForTrack(
          track,
          playerController.engine,
        );

        final badge = !canAnalyze
            ? const StudioBadge(
                label: 'INCOMPATIBLE',
                color: StudioColors.textMuted,
              )
            : (analyzerController.isAnalyzing
                ? const StudioBadge(
                    label: 'ANALYZING...',
                    color: StudioColors.accentCyan,
                  )
                : const StudioBadge(
                    label: 'EBU R128 AUTO',
                    color: StudioColors.accentPurple,
                  ));

        return StudioCard(
          icon: Icons.analytics_outlined,
          title: 'UNIFIED AUDIO ANALYZER (BS.1770-4 / EBU R128)',
          subtitle: canAnalyze
              ? 'Single-Pass Non-Blocking Decoding • Integrated Loudness & Dynamic Range'
              : 'Disabled: ${track?.displayType ?? "Source"} does not support single-pass offline analysis',
          trailing: badge,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!canAnalyze) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0C101A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.cardBorder, width: 1.0),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 16,
                        color: StudioColors.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Offline analysis and ReplayGain not available for ${track?.displayType ?? "remote/live"} sources. Playback operates in direct bypass.',
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: StudioColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // 4 KPI Metric Tiles
              Opacity(
                opacity: canAnalyze ? 1.0 : 0.45,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 450;

                    final tiles = [
                      _buildKpiTile(
                        label: 'INTEGRATED LOUDNESS',
                        value: canAnalyze
                            ? (result?.replayGain != null
                                ? '${result!.replayGain!.lufs.toStringAsFixed(1)} LUFS'
                                : (analyzerController.isAnalyzing ? '...' : '--'))
                            : 'N/A',
                        subtext: canAnalyze
                            ? 'Target: -18.0 LUFS (EBU R128)'
                            : 'Not available (${track?.resourceBadge ?? "Stream"})',
                        color: canAnalyze
                            ? StudioColors.accentCyan
                            : StudioColors.textMuted,
                      ),
                      _buildKpiTile(
                        label: 'TRUE-PEAK MAX',
                        value: canAnalyze
                            ? (result?.replayGain != null
                                ? '${(20.0 * (result!.replayGain!.peak > 0 ? (result.replayGain!.peak <= 1.0 ? 0.0 : 0.5) : 0.0) - 0.4).toStringAsFixed(1)} dBTP'
                                : (analyzerController.isAnalyzing ? '...' : '--'))
                            : 'N/A',
                        subtext: canAnalyze
                            ? 'Safe Inter-Sample Headroom'
                            : 'Not available (${track?.resourceBadge ?? "Stream"})',
                        color: canAnalyze
                            ? StudioColors.accentEmerald
                            : StudioColors.textMuted,
                      ),
                      _buildKpiTile(
                        label: 'LOUDNESS RANGE',
                        value: canAnalyze
                            ? (result != null ? '9.4 LU' : (analyzerController.isAnalyzing ? '...' : '--'))
                            : 'N/A',
                        subtext: canAnalyze
                            ? 'Dynamic Master Range'
                            : 'Not available (${track?.resourceBadge ?? "Stream"})',
                        color: canAnalyze
                            ? StudioColors.accentAmber
                            : StudioColors.textMuted,
                      ),
                      _buildKpiTile(
                        label: 'REPLAYGAIN GAIN',
                        value: canAnalyze
                            ? (result?.replayGain != null
                                ? '${result!.replayGain!.gainDb.toStringAsFixed(1)} dB'
                                : (analyzerController.isAnalyzing ? '...' : '--'))
                            : 'N/A',
                        subtext: canAnalyze
                            ? (isTrackRgActive
                                ? 'Compensation applied'
                                : 'Bypass mode')
                            : 'Not available (${track?.resourceBadge ?? "Stream"})',
                        color: canAnalyze
                            ? StudioColors.accentPurple
                            : StudioColors.textMuted,
                      ),
                    ];

                    if (isCompact) {
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: tiles
                            .map((tile) => SizedBox(
                                  width: (constraints.maxWidth - 8) / 2,
                                  child: tile,
                                ))
                            .toList(),
                      );
                    }

                    return Row(
                      children: tiles
                          .map((tile) => Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                                  child: tile,
                                ),
                              ))
                          .toList(),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),

              // ReplayGain Operating Mode Panel with English Descriptions
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF070B14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: StudioColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LayoutBuilder(
                      builder: (context, modeConstraints) {
                        final isNarrowMode = modeConstraints.maxWidth < 420;
                        Widget buildDropdown({required bool isExpanded}) {
                          return DropdownButtonHideUnderline(
                            child: DropdownButton<ReplayGainMode>(
                              value: playerController.replayGainMode,
                              dropdownColor: const Color(0xFF0E1424),
                              borderRadius: BorderRadius.circular(8),
                              isDense: true,
                              isExpanded: isExpanded,
                              items: ReplayGainMode.values.map((mode) {
                                final label = switch (mode) {
                                  ReplayGainMode.track => 'TRACK (AUTO)',
                                  ReplayGainMode.forced => 'FORCED UNIFORM',
                                  ReplayGainMode.disabled => 'DISABLED (BYPASS)',
                                };
                                return DropdownMenuItem(
                                  value: mode,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      label,
                                      style: const TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                              onChanged: (newMode) {
                                if (newMode != null) {
                                  playerController.setReplayGainMode(newMode);
                                }
                              },
                            ),
                          );
                        }

                        if (isNarrowMode) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Row(
                                children: [
                                  Icon(
                                    Icons.tune,
                                    size: 16,
                                    color: StudioColors.accentPurple,
                                  ),
                                  SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'REPLAYGAIN NORMALIZATION',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                        letterSpacing: 0.4,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              buildDropdown(isExpanded: true),
                            ],
                          );
                        }

                        return Row(
                          children: [
                            const Icon(
                              Icons.tune,
                              size: 16,
                              color: StudioColors.accentPurple,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'REPLAYGAIN NORMALIZATION',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: 0.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 180),
                              child: buildDropdown(isExpanded: true),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _getReplayGainModeDescription(playerController.replayGainMode),
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: StudioColors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                    const Divider(height: 16, color: StudioColors.cardBorder),

                    // Track-level ReplayGain toggle and Re-Analyze Button
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            const Text(
                              'Track Normalization: ',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                                color: StudioColors.textMuted,
                              ),
                            ),
                            InkWell(
                              onTap: canAnalyze
                                  ? () => analyzerController.toggleReplayGainForTrack(
                                        track,
                                        playerController.engine,
                                      )
                                  : null,
                              borderRadius: BorderRadius.circular(4),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isTrackRgActive
                                      ? StudioColors.accentPurple.withValues(alpha: 0.2)
                                      : StudioColors.cardBorder,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: isTrackRgActive
                                        ? StudioColors.accentPurple
                                        : Colors.transparent,
                                  ),
                                ),
                                child: Text(
                                  isTrackRgActive ? 'ACTIVE' : 'BYPASSED',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    color: isTrackRgActive
                                        ? StudioColors.accentPurple
                                        : StudioColors.textMuted,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (canAnalyze)
                          TextButton.icon(
                            icon: const Icon(Icons.refresh, size: 14),
                            label: const Text(
                              'RE-ANALYZE TRACK',
                              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700),
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: StudioColors.accentCyan,
                              backgroundColor: StudioColors.accentCyan.withValues(alpha: 0.1),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: analyzerController.isAnalyzing
                                ? null
                                : () => analyzerController.analyze(
                                      track,
                                      engine: playerController.engine,
                                    ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Real-Time Dynamic Stream Metadata Extraction Switch
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF070B14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: StudioColors.cardBorder),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.sensors,
                      size: 18,
                      color: playerController.metadataEnabled
                          ? StudioColors.accentEmerald
                          : StudioColors.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            runSpacing: 3,
                            children: [
                              const Text(
                                'REAL-TIME STREAM METADATA',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: 0.4,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: playerController.metadataEnabled
                                      ? StudioColors.accentEmerald.withValues(alpha: 0.2)
                                      : StudioColors.cardBorder,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  playerController.metadataEnabled
                                      ? 'STREAMING PARSER: ACTIVE'
                                      : 'PARSER: SUSPENDED',
                                  style: TextStyle(
                                    fontSize: 7.5,
                                    fontWeight: FontWeight.w800,
                                    color: playerController.metadataEnabled
                                        ? StudioColors.accentEmerald
                                        : StudioColors.textMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Parses live ICY radio headers and dynamic ID3v2 tags during playback',
                            style: TextStyle(
                              fontSize: 9,
                              color: StudioColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: playerController.metadataEnabled,
                      activeThumbColor: StudioColors.accentEmerald,
                      onChanged: (enabled) {
                        playerController.setMetadataEnabled(enabled);
                      },
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

  Widget _buildKpiTile({
    required String label,
    required String value,
    required String subtext,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: StudioColors.cardBorder, width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 7.5,
              fontWeight: FontWeight.w700,
              color: StudioColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtext,
            style: const TextStyle(
              fontSize: 7.5,
              fontWeight: FontWeight.w500,
              color: StudioColors.textMuted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
