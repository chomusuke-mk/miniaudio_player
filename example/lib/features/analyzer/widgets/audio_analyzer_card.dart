import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/models/audio_track.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_card.dart';
import '../../console/controllers/audio_engine_controller.dart';
import '../../metadata/widgets/acoustid_lookup_dialog.dart';
import '../controllers/audio_analyzer_controller.dart';
import 'analyzer_fingerprint_section.dart';
import 'analyzer_loudness_section.dart';
import 'analyzer_metadata_section.dart';
import 'analyzer_waveform_section.dart';

/// Card hosting the ITU-R BS.1770-4 / EBU R128 Unified Audio Analyzer.
///
/// Receives either static [analysis] metrics and [isLoading] directly, or binds
/// reactively to [analyzerController] and [playerController] for live updates.
/// Displays strictly `"loading..."` while pending and `"--"` when absent.
class AudioAnalyzerCard extends StatefulWidget {
  /// Complete acoustic analysis result, or `null` if unanalyzed.
  final AudioAnalysisResult? analysis;

  /// Whether an acoustic analysis background task is actively running.
  final bool isLoading;

  /// Callback to trigger re-analysis of the active audio source.
  final VoidCallback? onReanalyze;

  /// Whether the current track supports offline analysis.
  final bool canAnalyze;

  /// Associated audio track descriptor, if available.
  final AudioTrack? track;

  /// Optional controller reference for automatic reactive updates.
  final AudioEngineController? playerController;

  /// Optional analyzer controller reference for automatic reactive updates.
  final AudioAnalyzerController? analyzerController;

  /// Creates an [AudioAnalyzerCard] with optional precomputed [analysis],
  /// [isLoading] indicator, [onReanalyze] callback, [canAnalyze] capability flag,
  /// [track] descriptor, and reactive [playerController]/[analyzerController].
  const AudioAnalyzerCard({
    super.key,
    this.analysis,
    this.isLoading = false,
    this.onReanalyze,
    this.canAnalyze = true,
    this.track,
    this.playerController,
    this.analyzerController,
  });

  @override
  State<AudioAnalyzerCard> createState() => _AudioAnalyzerCardState();
}

/// Manages collapse state and controller composition inside [AudioAnalyzerCard].
class _AudioAnalyzerCardState extends State<AudioAnalyzerCard> {
  /// Whether the detailed waveform, metrics, and tag sections are expanded.
  bool _isExpanded = true;

  /// Builds the header status pill reflecting [canAnalyze], [isLoading], and
  /// [isReady] states.
  Widget _buildStatusPill({
    required bool canAnalyze,
    required bool isLoading,
    required bool isReady,
  }) {
    if (!canAnalyze) {
      return const StudioBadge(
        label: 'STREAM ONLY',
        color: StudioColors.textMuted,
      );
    }

    if (isLoading) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
        decoration: BoxDecoration(
          color: StudioColors.accentCyan.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: StudioColors.accentCyan, width: 1.0),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sync, size: 11, color: StudioColors.accentCyan),
            SizedBox(width: 5),
            Text(
              'ANALYZING',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: StudioColors.accentCyan,
              ),
            ),
          ],
        ),
      );
    }

    if (isReady) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
        decoration: BoxDecoration(
          color: StudioColors.accentEmerald.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: StudioColors.accentEmerald, width: 1.0),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 11,
              color: StudioColors.accentEmerald,
            ),
            SizedBox(width: 4),
            Text(
              'READY',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: StudioColors.accentEmerald,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: StudioColors.accentAmber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: StudioColors.accentAmber, width: 1.0),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.hourglass_empty,
            size: 10,
            color: StudioColors.accentAmber,
          ),
          SizedBox(width: 4),
          Text(
            'STANDBY',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: StudioColors.accentAmber,
            ),
          ),
        ],
      ),
    );
  }

  /// Lays out the four sub-cards ([replayGainWidget], [audioInfoWidget],
  /// [metadataWidget], and [chromaprintWidget]) across 4 columns (`>=760`),
  /// 2x2 grid (`500..759`), or single-column stack (`<500`) inside [maxWidth].
  Widget _buildResponsiveSubCardsGrid({
    required double maxWidth,
    required Widget replayGainWidget,
    required Widget audioInfoWidget,
    required Widget metadataWidget,
    required Widget chromaprintWidget,
  }) {
    if (maxWidth >= 760) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: replayGainWidget),
          const SizedBox(width: 12),
          Expanded(child: audioInfoWidget),
          const SizedBox(width: 12),
          Expanded(child: metadataWidget),
          const SizedBox(width: 12),
          Expanded(child: chromaprintWidget),
        ],
      );
    }

    if (maxWidth >= 500) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: replayGainWidget),
              const SizedBox(width: 12),
              Expanded(child: audioInfoWidget),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: metadataWidget),
              const SizedBox(width: 12),
              Expanded(child: chromaprintWidget),
            ],
          ),
        ],
      );
    }

    final cards = [
      replayGainWidget,
      audioInfoWidget,
      metadataWidget,
      chromaprintWidget,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          cards[i],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[];
    if (widget.analyzerController != null) {
      listenables.add(widget.analyzerController!);
    }
    if (widget.playerController != null) {
      listenables.add(widget.playerController!.trackSelectionListenable);
    }

    if (listenables.isNotEmpty) {
      return ListenableBuilder(
        listenable: Listenable.merge(listenables),
        builder: (context, _) {
          final effectiveTrack =
              widget.track ?? widget.playerController?.selectedTrack;
          final effectiveCanAnalyze =
              widget.canAnalyze && (effectiveTrack?.canAnalyze ?? true);
          final effectiveAnalysis =
              widget.analysis ??
              widget.analyzerController?.getResultForTrack(effectiveTrack);
          final effectiveIsLoading =
              widget.isLoading ||
              (widget.analyzerController?.isAnalyzingTrack(effectiveTrack) ??
                  false);
          final effectiveOnReanalyze =
              widget.onReanalyze ??
              (effectiveCanAnalyze && effectiveTrack != null
                  ? () {
                      MapLogger.info(
                        '[ANALYZER:UI] Triggering manual re-analysis for "${effectiveTrack.title}"',
                      );
                      widget.analyzerController?.analyze(
                        effectiveTrack,
                        engine: widget.playerController?.engine,
                        force: true,
                      );
                    }
                  : null);

          return _buildContent(
            context: context,
            track: effectiveTrack,
            analysis: effectiveAnalysis,
            isLoading: effectiveIsLoading,
            canAnalyze: effectiveCanAnalyze,
            onReanalyze: effectiveOnReanalyze,
          );
        },
      );
    }

    return _buildContent(
      context: context,
      track: widget.track,
      analysis: widget.analysis,
      isLoading: widget.isLoading,
      canAnalyze: widget.canAnalyze,
      onReanalyze: widget.onReanalyze,
    );
  }

  /// Renders the outer [StudioCard] and composes the waveform, loudness, info,
  /// metadata, and Chromaprint sections for [track] and [analysis].
  Widget _buildContent({
    required BuildContext context,
    required AudioTrack? track,
    required AudioAnalysisResult? analysis,
    required bool isLoading,
    required bool canAnalyze,
    required VoidCallback? onReanalyze,
  }) {
    final isReady = analysis != null;
    final chromaprint = analysis?.chromaprint;
    final fpString = chromaprint?.fingerprint;
    final durationSeconds =
        (analysis?.audioInfo.duration?.inMilliseconds ?? 0) / 1000.0;

    return StudioCard(
      icon: Icons.analytics_outlined,
      title: 'UNIFIED AUDIO ANALYZER',
      subtitle: canAnalyze
          ? 'BS.1770-4 / EBU R128 single-pass acoustic decoding & header probing'
          : 'Disabled: ${track?.displayType ?? "Source"} does not support single-pass offline analysis',
      showChild: _isExpanded,
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2,
        runSpacing: 4,
        children: [
          _buildStatusPill(
            canAnalyze: canAnalyze,
            isLoading: isLoading,
            isReady: isReady,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 18),
            color: canAnalyze && !isLoading
                ? StudioColors.accentCyan
                : StudioColors.textMuted,
            tooltip: 'Re-analyze Track',
            visualDensity: VisualDensity.compact,
            onPressed: canAnalyze && !isLoading ? onReanalyze : null,
          ),
          IconButton(
            icon: Icon(
              _isExpanded
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.keyboard_arrow_up_rounded,
              size: 20,
            ),
            color: StudioColors.textSecondary,
            tooltip: _isExpanded ? 'Hide Analyzer Body' : 'Show Analyzer Body',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
          ),
        ],
      ),
      child: _isExpanded
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnalyzerWaveformSection(
                  points: analysis?.waveform?.points ?? const <double>[],
                  isLoading: isLoading,
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isFourColumn = constraints.maxWidth >= 760;
                    final replayGainWidget = AnalyzerLoudnessSection(
                      replayGain: analysis?.replayGain,
                      isLoading: isLoading,
                    );
                    final audioInfoWidget = AnalyzerAudioInfoSection(
                      audioInfo: analysis?.audioInfo,
                      analysisDurationMs: widget.analyzerController
                          ?.getDurationMsForTrack(track),
                      servedFromCache:
                          widget.analyzerController?.wasLastServedFromCache(
                            track,
                          ) ??
                          false,
                      isLoading: isLoading,
                    );
                    final metadataWidget = AnalyzerMetadataSection(
                      metadata: analysis?.metadata,
                      trackTitle: track?.title ?? 'Track',
                      isLoading: isLoading,
                    );
                    final chromaprintWidget = AnalyzerFingerprintSection(
                      chromaprint: chromaprint,
                      isLoading: isLoading,
                      fingerprintMaxLines: isFourColumn ? 14 : 2,
                      onIdentifyTrack:
                          (fpString != null &&
                              fpString.isNotEmpty &&
                              widget.analyzerController != null)
                          ? () {
                              MapLogger.info(
                                '[ANALYZER:UI] Opening AcoustID lookup dialog for "${track?.title ?? 'Track'}"',
                              );
                              showDialog<void>(
                                context: context,
                                builder: (_) => AcoustIdLookupDialog(
                                  fingerprint: fpString,
                                  durationSeconds: durationSeconds,
                                  trackTitle: track?.title ?? 'Track',
                                  analyzerController:
                                      widget.analyzerController!,
                                ),
                              );
                            }
                          : null,
                    );

                    return _buildResponsiveSubCardsGrid(
                      maxWidth: constraints.maxWidth,
                      replayGainWidget: replayGainWidget,
                      audioInfoWidget: audioInfoWidget,
                      metadataWidget: metadataWidget,
                      chromaprintWidget: chromaprintWidget,
                    );
                  },
                ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}
