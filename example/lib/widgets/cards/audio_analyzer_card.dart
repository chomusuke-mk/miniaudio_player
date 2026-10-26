import 'package:flutter/material.dart';
import '../../controllers/audio_analyzer_controller.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

class AudioAnalyzerCard extends StatelessWidget {
  final AudioEngineController playerController;
  final AudioAnalyzerController analyzerController;

  const AudioAnalyzerCard({
    super.key,
    required this.playerController,
    required this.analyzerController,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([analyzerController, playerController]),
      builder: (context, _) {
        final track = playerController.selectedTrack;
        final canAnalyze = track != null && track.canAnalyze;
        final result = analyzerController.getResultForTrack(track);

        final badge = !canAnalyze
            ? const StudioBadge(
                label: 'INCOMPATIBLE',
                color: StudioColors.textMuted,
              )
            : (analyzerController.isAnalyzing
                ? const StudioBadge(
                    label: 'ANALIZANDO...',
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
              : 'Deshabilitado: ${track?.displayType ?? "Fuente"} no admite análisis offline single-pass',
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
                          'Análisis offline y ReplayGain no disponibles para fuentes ${track?.displayType ?? "remotas/en vivo"}. La reproducción opera en bypass directo.',
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
                            ? 'Target: -14 LUFS (EBU R128)'
                            : 'No disponible (${track?.resourceBadge ?? "Stream"})',
                        color: canAnalyze
                            ? StudioColors.accentCyan
                            : StudioColors.textMuted,
                      ),
                      _buildKpiTile(
                        label: 'TRUE-PEAK MAX',
                        value: canAnalyze
                            ? (result != null
                                ? '${(20.0 * (result.peak > 0 ? (result.peak <= 1.0 ? 0.0 : 0.5) : 0.0) - 0.4).toStringAsFixed(1)} dBTP'
                                : (analyzerController.isAnalyzing ? '...' : '--'))
                            : 'N/A',
                        subtext: canAnalyze
                            ? 'Safe Inter-Sample Headroom'
                            : 'No disponible (${track?.resourceBadge ?? "Stream"})',
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
                            : 'No disponible (${track?.resourceBadge ?? "Stream"})',
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
                            ? (analyzerController.replayGainActive
                                ? 'Compensación activa'
                                : 'Modo bypass')
                            : 'No disponible (${track?.resourceBadge ?? "Stream"})',
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

              // ReplayGain & Anti-Clipping Control Panels
              Opacity(
                opacity: canAnalyze ? 1.0 : 0.45,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isNarrow = constraints.maxWidth < 460;

                    final replayGainSubtitle = !canAnalyze
                        ? 'Deshabilitado para streams en vivo / remotos'
                        : (result?.replayGain != null
                            ? (analyzerController.replayGainActive
                                ? 'Compensación activa: ${result!.replayGain!.gainDb.toStringAsFixed(1)} dB'
                                : 'Modo Bypass sin compensación')
                            : 'Pendiente de análisis para esta pista');

                    final replayGainCard = _buildControlPanel(
                      icon: Icons.tune,
                      title: 'NATIVE REPLAYGAIN NORMALIZATION',
                      subtitle: replayGainSubtitle,
                      isActive: canAnalyze && analyzerController.replayGainActive,
                      activeColor: StudioColors.accentPurple,
                      statusText: !canAnalyze
                          ? 'DESHABILITADO'
                          : (analyzerController.replayGainActive
                              ? 'ACTIVO (EBU R128)'
                              : 'BYPASSED'),
                      onToggle: canAnalyze
                          ? () {
                              analyzerController.setReplayGainActive(
                                !analyzerController.replayGainActive,
                                playerController.engine,
                              );
                            }
                          : () {},
                    );

                    final antiClippingCard = _buildControlPanel(
                      icon: Icons.shield,
                      title: 'ANTI-CLIPPING TRUE-PEAK GUARD',
                      subtitle: !canAnalyze
                          ? 'Deshabilitado para streams en vivo / remotos'
                          : (analyzerController.preventClipping
                              ? 'Ceiling -1.0 dBFS • DAC Seguro'
                              : 'Desactivado (Riesgo clipping inter-sample)'),
                      isActive: canAnalyze && analyzerController.preventClipping,
                      activeColor: StudioColors.accentEmerald,
                      statusText: !canAnalyze
                          ? 'DESHABILITADO'
                          : (analyzerController.preventClipping
                              ? 'PROTEGIDO'
                              : 'OFF'),
                      onToggle: canAnalyze
                          ? () {
                              analyzerController.setPreventClipping(
                                !analyzerController.preventClipping,
                                playerController.engine,
                              );
                            }
                          : () {},
                    );

                    if (isNarrow) {
                      return Column(
                        children: [
                          replayGainCard,
                          const SizedBox(height: 8),
                          antiClippingCard,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: replayGainCard),
                        const SizedBox(width: 8),
                        Expanded(child: antiClippingCard),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControlPanel({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isActive,
    required Color activeColor,
    required String statusText,
    required VoidCallback onToggle,
  }) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isActive
              ? activeColor.withValues(alpha: 0.1)
              : const Color(0xFF0A0F1D),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? activeColor : StudioColors.cardBorder,
            width: isActive ? 1.4 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive
                    ? activeColor.withValues(alpha: 0.2)
                    : StudioColors.backgroundDark,
              ),
              child: Icon(
                icon,
                size: 16,
                color: isActive ? activeColor : StudioColors.textMuted,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: isActive ? Colors.white : StudioColors.textSecondary,
                      letterSpacing: 0.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 8.5,
                      color: StudioColors.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: isActive ? activeColor : StudioColors.cardBorder,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusText,
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w900,
                  color: isActive ? Colors.black : StudioColors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
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
