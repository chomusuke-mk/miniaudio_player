import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_analyzer_controller.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../models/audio_track.dart';
import '../../theme/studio_colors.dart';
import '../common/acoustid_lookup_dialog.dart';
import '../common/extended_metadata_dialog.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';
import '../common/thumbnails_viewer_dialog.dart';
import '../painters/discrete_waveform_painter.dart';

/// Card hosting the ITU-R BS.1770-4 / EBU R128 Unified Audio Analyzer.
///
/// Receives the complete acoustic [analysis] object (`AudioAnalysisResult?`)
/// and a [isLoading] flag. When loading, all fields display "loading..." in gray.
/// If analysis is null or any field is null, it displays strictly "--" without
/// any fallbacks or defaults.
class AudioAnalyzerCard extends StatefulWidget {
  /// Complete acoustic analysis result, or null if unanalyzed.
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

class _AudioAnalyzerCardState extends State<AudioAnalyzerCard> {
  bool _isExpanded = true;

  String _formatDuration(Duration? d) {
    if (d == null || d == Duration.zero) return '--';
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$ms';
  }

  String _formatByteSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '--';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  String _formatTotalFrames(AudioInfo? info) {
    if (info == null ||
        info.sampleRate <= 0 ||
        info.duration == null ||
        info.duration! <= Duration.zero) {
      return '--';
    }
    final frames = (info.sampleRate * info.duration!.inMicroseconds / 1000000)
        .round();
    if (frames <= 0) return '--';
    final digits = frames.toString();
    final buf = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buf.write(',');
      }
      buf.write(digits[i]);
    }
    return buf.toString();
  }

  String _resolveText(String? val, bool isLoading) {
    if (isLoading) return 'loading...';
    if (val == null || val.trim().isEmpty) return '--';
    return val;
  }

  Widget _buildPropertyRow(String label, String value, bool isLoading) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 9,
                color: StudioColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 9,
                color: isLoading ? const Color(0xFF64748B) : Colors.white,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubCardHeader({
    required IconData icon,
    required Color accentColor,
    required String title,
    String? subtitle,
    List<InlineSpan>? subtitleSpans,
    Widget? trailing,
  }) {
    final titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: accentColor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: accentColor,
            ),
          ),
        ),
      ],
    );

    const subtitleStyle = TextStyle(
      fontSize: 8.5,
      color: StudioColors.textMuted,
      height: 1.3,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1424),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
        border: Border(
          bottom: BorderSide(
            color: StudioColors.cardBorder.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (trailing == null)
            titleRow
          else
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 2,
              children: [titleRow, trailing],
            ),
          if (subtitleSpans != null) ...[
            const SizedBox(height: 3),
            Text.rich(
              TextSpan(style: subtitleStyle, children: subtitleSpans),
            ),
          ] else if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(subtitle, style: subtitleStyle),
          ],
        ],
      ),
    );
  }

  int _countExtendedFields(AudioMetadata? metadata) {
    if (metadata == null) return 0;
    int count = 0;
    final ext = metadata.extended;
    final fields = [
      ext.isrc,
      ext.barcode,
      ext.catalogNumber,
      ext.label,
      ext.publisher,
      ext.musicBrainzTrackId,
      ext.musicBrainzRecordingId,
      ext.musicBrainzReleaseId,
      ext.musicBrainzArtistId,
      ext.musicBrainzReleaseArtistId,
      ext.musicBrainzWorkId,
      ext.musicBrainzReleaseType,
      ext.acoustId,
      ext.composer,
      ext.lyricist,
      ext.producer,
      ext.engineer,
      ext.arranger,
      ext.conductor,
      ext.performer,
      ext.remixer,
      ext.mixDj,
      ext.director,
      ext.releaseDate,
      ext.originalReleaseDate,
      ext.recordingDate,
      ext.initialKey,
      ext.mood,
      ext.color,
      ext.copyrightMessage,
      ext.license,
      ext.copyrightUrl,
      ext.commercialInformationUrl,
    ];
    for (final f in fields) {
      if (f != null && f.trim().isNotEmpty) count++;
    }
    if (metadata.bpm != null) count++;
    if (metadata.lyrics != null && metadata.lyrics!.trim().isNotEmpty) count++;
    count += metadata.chapters.length;
    count += metadata.customTags.length;
    return count;
  }

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

  @override
  Widget build(BuildContext context) {
    // If controller references are passed, merge listenables for real-time reactivity
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
                  ? () => widget.analyzerController?.analyze(
                      effectiveTrack,
                      engine: widget.playerController?.engine,
                      force: true,
                    )
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

  Widget _buildContent({
    required BuildContext context,
    required AudioTrack? track,
    required AudioAnalysisResult? analysis,
    required bool isLoading,
    required bool canAnalyze,
    required VoidCallback? onReanalyze,
  }) {
    final isReady = analysis != null;

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
                // 1. WAVEFORM SECTION
                _buildWaveformSection(analysis, isLoading),
                const SizedBox(height: 14),

                // 2, 3, 4 & 5. REPLAY GAIN, AUDIO INFO, METADATA & CHROMAPRINT
                // Responsive: 4 columns (1/4 each) -> 2x2 (1/2 each) -> 1 column stack
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isFourColumn = constraints.maxWidth >= 760;
                    final replayGainWidget = _buildReplayGainSection(
                      analysis,
                      isLoading,
                    );
                    final audioInfoWidget = _buildAudioInfoSection(
                      analysis,
                      isLoading,
                      track,
                    );
                    final metadataWidget = _buildMetadataSection(
                      context,
                      analysis,
                      isLoading,
                      track,
                    );
                    final chromaprintWidget = _buildChromaprintSection(
                      context,
                      analysis,
                      isLoading,
                      track,
                      fingerprintMaxLines: isFourColumn ? 14 : 2,
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

  // ===========================================================================
  // REPLAY GAIN SECTION (Vertical card at start of analyzer sub-cards row)
  // ===========================================================================
  Widget _buildReplayGainSection(
    AudioAnalysisResult? analysis,
    bool isLoading,
  ) {
    final rg = analysis?.replayGain;

    final String gainStr;
    final Color gainColor;
    final String peakStr;
    final Color peakColor;
    final String lufsStr;
    final Color lufsColor;

    if (isLoading) {
      gainStr = 'loading...';
      gainColor = const Color(0xFF64748B);
      peakStr = 'loading...';
      peakColor = const Color(0xFF64748B);
      lufsStr = 'loading...';
      lufsColor = const Color(0xFF64748B);
    } else if (rg != null) {
      gainStr = '${rg.gainDb.toStringAsFixed(1)} dB';
      gainColor = StudioColors.accentPurple;
      peakStr = rg.peak.toStringAsFixed(4);
      peakColor = StudioColors.accentEmerald;
      lufsStr = '${rg.lufs.toStringAsFixed(1)} LUFS';
      lufsColor = StudioColors.accentCyan;
    } else {
      gainStr = '--';
      gainColor = StudioColors.textMuted;
      peakStr = '--';
      peakColor = StudioColors.textMuted;
      lufsStr = '--';
      lufsColor = StudioColors.textMuted;
    }

    final tiles = [
      _buildCompactKpiTile(
        label: 'REPLAY GAIN',
        value: gainStr,
        color: gainColor,
      ),
      _buildCompactKpiTile(
        label: 'TRUE-PEAK',
        value: peakStr,
        color: peakColor,
      ),
      _buildCompactKpiTile(
        label: 'INTEGRATED LOUDNESS',
        value: lufsStr,
        color: lufsColor,
      ),
    ];

    final String peakDbfsStr;
    final String headroomStr;
    final String clipGuardStr;
    if (isLoading) {
      peakDbfsStr = 'loading...';
      headroomStr = 'loading...';
      clipGuardStr = 'loading...';
    } else if (rg != null) {
      if (rg.peak > 0) {
        final dbfs = 20 * math.log(rg.peak) / math.ln10;
        peakDbfsStr = '${dbfs.toStringAsFixed(2)} dBFS';
        headroomStr = rg.peak <= 1.0
            ? '+${(-dbfs).toStringAsFixed(2)} dB'
            : '-${dbfs.toStringAsFixed(2)} dB';
      } else {
        peakDbfsStr = '-inf dBFS';
        headroomStr = 'Full';
      }
      clipGuardStr = rg.peak > 1.0 ? 'Over 0 dBFS' : 'Safe (<= 1.0)';
    } else {
      peakDbfsStr = '--';
      headroomStr = '--';
      clipGuardStr = '--';
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSubCardHeader(
            icon: Icons.tune,
            accentColor: StudioColors.accentPurple,
            title: 'REPLAY GAIN (BS.1770-4 / EBU R128)',
            subtitle:
                'ReplayGain normalizes playback volume to target loudness (-18.0 LUFS). Peak represents true-peak sample headroom to prevent clipping, and Gain specifies the recommended volume compensation offset.',
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  tiles[i],
                ],
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0F1D),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: StudioColors.cardBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildPropertyRow(
                        'Target Ref',
                        isLoading ? 'loading...' : '-18.0 LUFS',
                        isLoading,
                      ),
                      _buildPropertyRow('Peak dBFS', peakDbfsStr, isLoading),
                      _buildPropertyRow('Headroom', headroomStr, isLoading),
                      _buildPropertyRow('Clip Guard', clipGuardStr, isLoading),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactKpiTile({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              color: StudioColors.textSecondary,
              letterSpacing: 0.4,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 2. WAVEFORM SECTION
  // ===========================================================================
  Widget _buildWaveformSection(AudioAnalysisResult? analysis, bool isLoading) {
    final points = analysis?.waveform?.points ?? const <double>[];

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.graphic_eq,
                size: 14,
                color: StudioColors.accentCyan,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'WAVEFORM PROFILE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (points.isNotEmpty && !isLoading)
                Text(
                  '${points.length} blocks',
                  style: const TextStyle(
                    fontSize: 8.5,
                    color: StudioColors.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Normalized dynamic amplitude energy envelope over time. Rendered as discrete, un-smoothed rectangular blocks showing raw peak values per sample slice.',
            style: TextStyle(
              fontSize: 9,
              color: StudioColors.textMuted,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),

          // Discrete Waveform Canvas
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0F1D),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: StudioColors.cardBorder, width: 0.8),
            ),
            child: (points.isEmpty || isLoading)
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      const CustomPaint(
                        size: Size.infinite,
                        painter: DiscreteWaveformPainter(
                          points: [],
                          barColor: StudioColors.accentCyan,
                        ),
                      ),
                      Text(
                        isLoading ? 'loading...' : '--',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: isLoading
                              ? const Color(0xFF64748B)
                              : StudioColors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  )
                : CustomPaint(
                    size: Size.infinite,
                    painter: DiscreteWaveformPainter(
                      points: points,
                      barColor: StudioColors.accentCyan,
                    ),
                  ),
          ),
          if (points.isNotEmpty && !isLoading) ...[
            const SizedBox(height: 8),
            _buildWaveformTelemetryStrip(points),
          ],
        ],
      ),
    );
  }

  Widget _buildWaveformTelemetryStrip(List<double> points) {
    final maxPt = points.reduce(math.max);
    final minPt = points.reduce(math.min);
    final meanRms = math.sqrt(
      points.fold<double>(0.0, (sum, p) => sum + p * p) / points.length,
    );
    final crestStr = meanRms > 0
        ? '${(20 * math.log(maxPt / meanRms) / math.ln10).toStringAsFixed(1)} dB'
        : '--';

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _buildMiniTelemetryBadge(
          'PEAK',
          '${(maxPt * 100).toStringAsFixed(0)}%',
          StudioColors.accentCyan,
        ),
        _buildMiniTelemetryBadge(
          'MEAN RMS',
          '${(meanRms * 100).toStringAsFixed(0)}%',
          StudioColors.accentViolet,
        ),
        _buildMiniTelemetryBadge(
          'FLOOR',
          '${(minPt * 100).toStringAsFixed(0)}%',
          StudioColors.textSecondary,
        ),
        _buildMiniTelemetryBadge('CREST', crestStr, StudioColors.accentEmerald),
        _buildMiniTelemetryBadge(
          'DECIMATION',
          '<= 2048 buckets',
          StudioColors.accentAmber,
        ),
      ],
    );
  }

  Widget _buildMiniTelemetryBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w600,
                color: StudioColors.textMuted,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 3. AUDIO INFO SECTION (Flex 50% / 100%)
  // ===========================================================================
  Widget _buildAudioInfoSection(
    AudioAnalysisResult? analysis,
    bool isLoading,
    AudioTrack? track,
  ) {
    final info = analysis?.audioInfo;
    final durationMs = widget.analyzerController?.getDurationMsForTrack(track);
    final servedFromCache =
        widget.analyzerController?.wasLastServedFromCache(track) ?? false;
    final String pcmThroughputStr;
    if (isLoading) {
      pcmThroughputStr = 'loading...';
    } else if (info != null && info.sampleRate > 0 && info.channels > 0) {
      final bits = (info.bitsPerSample != null && info.bitsPerSample! > 0)
          ? info.bitsPerSample!
          : 32;
      final kbps = (info.sampleRate * info.channels * bits / 1000).round();
      pcmThroughputStr = '$kbps kbps';
    } else {
      pcmThroughputStr = '--';
    }

    final String analyzeTimeStr;
    if (isLoading) {
      analyzeTimeStr = 'loading...';
    } else if (servedFromCache) {
      analyzeTimeStr = durationMs != null
          ? '0 ms (cached • ${durationMs}ms pass)'
          : '0 ms (cache hit)';
    } else if (durationMs != null) {
      analyzeTimeStr = '$durationMs ms (1-pass)';
    } else {
      analyzeTimeStr = '--';
    }

    final rows = <(String, String)>[
      (
        'Container Format',
        _resolveText(info?.containerFormat ?? info?.format, isLoading),
      ),
      ('Format', _resolveText(info?.format, isLoading)),
      ('Audio Codec', _resolveText(info?.codec, isLoading)),
      (
        'Sample Rate',
        isLoading
            ? 'loading...'
            : (info != null && info.sampleRate > 0
                  ? '${info.sampleRate} Hz'
                  : '--'),
      ),
      (
        'Raw Sample Rate',
        isLoading
            ? 'loading...'
            : (info?.rawSampleRate != null && info!.rawSampleRate! > 0
                  ? '${info.rawSampleRate} Hz'
                  : '--'),
      ),
      (
        'Channels',
        isLoading
            ? 'loading...'
            : (info != null && info.channels > 0
                  ? '${info.channels} ch'
                  : '--'),
      ),
      (
        'Bit Depth',
        isLoading
            ? 'loading...'
            : (info?.bitsPerSample != null && info!.bitsPerSample! > 0
                  ? '${info.bitsPerSample}-bit'
                  : '--'),
      ),
      (
        'Bitrate',
        isLoading
            ? 'loading...'
            : (info?.bitrate != null && info!.bitrate > 0
                  ? '${(info.bitrate / 1000).round()} kbps'
                  : '--'),
      ),
      (
        'Bitrate Mode',
        isLoading
            ? 'loading...'
            : (info != null && info.bitrateMode != BitrateMode.unknown
                  ? info.bitrateMode.name.toUpperCase()
                  : '--'),
      ),
      ('Decoded PCM', pcmThroughputStr),
      (
        'Duration',
        isLoading
            ? 'loading...'
            : (info != null && info.duration != Duration.zero
                  ? _formatDuration(info.duration)
                  : '--'),
      ),
      (
        'Total Frames', isLoading ? 'loading...' : _formatTotalFrames(info)),
      ('File Size', isLoading ? 'loading...' : _formatByteSize(info?.fileSize)),
      (
        'Lossless',
        isLoading
            ? 'loading...'
            : (info?.lossless == true
                  ? 'Lossless'
                  : (info?.lossless == false ? 'Lossy' : '--')),
      ),
      ('Analysis Pass', analyzeTimeStr),
    ];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Section Header
          _buildSubCardHeader(
            icon: Icons.info_outline,
            accentColor: StudioColors.accentCyan,
            title: 'AUDIO INFO',
            subtitle: 'Extracted directly from headers at zero decoding cost without affecting playback performance.',
          ),

          // Properties Table
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: rows
                  .map((r) => _buildPropertyRow(r.$1, r.$2, isLoading))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 4. METADATA SECTION (Flex 50% / 100%)
  // ===========================================================================
  Widget _buildMetadataSection(
    BuildContext context,
    AudioAnalysisResult? analysis,
    bool isLoading,
    AudioTrack? track,
  ) {
    final metadata = analysis?.metadata;
    final pictures = metadata?.pictures ?? const <AudioPicture>[];
    final extendedCount = _countExtendedFields(metadata);

    final rows = <(String, String)>[
      ('Title', _resolveText(metadata?.title, isLoading)),
      ('Artist', _resolveText(metadata?.trackArtist, isLoading)),
      ('Album', _resolveText(metadata?.album, isLoading)),
      (
        'Year / Date',
        _resolveText(
          metadata?.year?.toString() ?? metadata?.extended.originalReleaseDate,
          isLoading,
        ),
      ),
      ('Genre', _resolveText(metadata?.genre, isLoading)),
      (
        'Track #',
        isLoading
            ? 'loading...'
            : (metadata?.trackNumber != null
                  ? '${metadata!.trackNumber}/${metadata.trackTotal ?? "-"}'
                  : '--'),
      ),
      ('RG Track Gain', _resolveText(metadata?.replayGainTrackGain, isLoading)),
      ('RG Track Peak', _resolveText(metadata?.replayGainTrackPeak, isLoading)),
      ('RG Album Gain', _resolveText(metadata?.replayGainAlbumGain, isLoading)),
      ('RG Album Peak', _resolveText(metadata?.replayGainAlbumPeak, isLoading)),
      (
        'BPM',
        isLoading
            ? 'loading...'
            : (metadata?.bpm != null
                  ? metadata!.bpm!.toStringAsFixed(1)
                  : '--'),
      ),
      (
        'Chapters',
        isLoading
            ? 'loading...'
            : (metadata != null && metadata.chapters.isNotEmpty
                  ? '${metadata.chapters.length}'
                  : '--'),
      ),
      (
        'Lyrics',
        isLoading
            ? 'loading...'
            : (metadata?.lyrics != null && metadata!.lyrics!.trim().isNotEmpty
                  ? '${metadata.lyrics!.trim().length} chars'
                  : '--'),
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Section Header
          _buildSubCardHeader(
            icon: Icons.library_music_outlined,
            accentColor: StudioColors.accentPurple,
            title: 'METADATA',
            subtitle: 'Embedded tags, album credits, multi-image artwork thumbnails, and extended studio credits.',
          ),

          // Properties Table
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                ...rows.map((r) => _buildPropertyRow(r.$1, r.$2, isLoading)),

                // Thumbnails Row (Interactive list with overflow & modal on tap)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 86,
                        child: Text(
                          'Thumbnails',
                          style: TextStyle(
                            fontSize: 9,
                            color: StudioColors.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        child: isLoading
                            ? const Text(
                                'loading...',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Color(0xFF64748B),
                                  fontFamily: 'monospace',
                                ),
                              )
                            : (pictures.isEmpty
                                  ? const Text(
                                      '--',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: StudioColors.textMuted,
                                        fontFamily: 'monospace',
                                      ),
                                    )
                                  : Align(
                                      alignment: Alignment.centerLeft,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerLeft,
                                        child: InkWell(
                                          onTap: () {
                                            showDialog(
                                              context: context,
                                              builder: (_) =>
                                                  ThumbnailsViewerDialog(
                                                    pictures: pictures,
                                                    trackTitle:
                                                        track?.title ?? 'Track',
                                                  ),
                                            );
                                          },
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              ...pictures.take(3).map((pic) {
                                                return Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        right: 4,
                                                      ),
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          3,
                                                        ),
                                                    child: Container(
                                                      width: 20,
                                                      height: 20,
                                                      color: const Color(
                                                        0xFF0E1424,
                                                      ),
                                                      child: Image.memory(
                                                        pic.bytes,
                                                        fit: BoxFit.cover,
                                                        errorBuilder:
                                                            (
                                                              context,
                                                              error,
                                                              stackTrace,
                                                            ) => const Icon(
                                                              Icons.image,
                                                              size: 14,
                                                              color: StudioColors
                                                                  .textMuted,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              }),
                                              if (pictures.length > 3)
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 4,
                                                        vertical: 1.5,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        StudioColors.cardBorder,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          3,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    '+${pictures.length - 3}...',
                                                    style: const TextStyle(
                                                      fontSize: 7.5,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ),
                                              const SizedBox(width: 4),
                                              const Icon(
                                                Icons.open_in_new,
                                                size: 11,
                                                color: StudioColors.accentCyan,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    )),
                      ),
                    ],
                  ),
                ),

                // Extended Metadata Row (Button opening modal)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 86,
                        child: Text(
                          'Extended Tags',
                          style: TextStyle(
                            fontSize: 9,
                            color: StudioColors.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        child: isLoading
                            ? const Text(
                                'loading...',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Color(0xFF64748B),
                                  fontFamily: 'monospace',
                                ),
                              )
                            : (extendedCount == 0
                                  ? const Text(
                                      '--',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: StudioColors.textMuted,
                                        fontFamily: 'monospace',
                                      ),
                                    )
                                  : Align(
                                      alignment: Alignment.centerLeft,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerLeft,
                                        child: InkWell(
                                          onTap: () {
                                            showDialog(
                                              context: context,
                                              builder: (_) =>
                                                  ExtendedMetadataDialog(
                                                    metadata: metadata,
                                                    trackTitle:
                                                        track?.title ?? 'Track',
                                                  ),
                                            );
                                          },
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: StudioColors.accentPurple
                                                  .withValues(alpha: 0.15),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              border: Border.all(
                                                color: StudioColors.accentPurple
                                                    .withValues(alpha: 0.4),
                                                width: 0.8,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.open_in_new,
                                                  size: 10,
                                                  color:
                                                      StudioColors.accentPurple,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  'VIEW EXTENDED ($extendedCount)',
                                                  style: const TextStyle(
                                                    fontSize: 8.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: StudioColors
                                                        .accentPurple,
                                                    letterSpacing: 0.3,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    )),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 5. CHROMAPRINT / ACOUSTID FINGERPRINT SECTION
  // ===========================================================================
  Widget _buildChromaprintSection(
    BuildContext context,
    AudioAnalysisResult? analysis,
    bool isLoading,
    AudioTrack? track, {
    int fingerprintMaxLines = 2,
  }) {
    final chromaprint = analysis?.chromaprint;
    final fpString = chromaprint?.fingerprint;
    final algorithm = chromaprint?.algorithm;
    final durationSeconds =
        (analysis?.audioInfo.duration?.inMilliseconds ?? 0) / 1000.0;

    final String algoText;
    final Color algoColor;
    if (isLoading) {
      algoText = 'Algorithm: loading...';
      algoColor = const Color(0xFF64748B);
    } else if (chromaprint != null) {
      algoText = 'ALGORITHM TEST2 ($algorithm)';
      algoColor = StudioColors.accentCyan;
    } else {
      algoText = 'Algorithm: --';
      algoColor = StudioColors.textMuted;
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Section Header
          _buildSubCardHeader(
            icon: Icons.fingerprint,
            accentColor: StudioColors.accentCyan,
            title: 'CHROMAPRINT / ACOUSTID FINGERPRINT',
            subtitleSpans: [
              const TextSpan(
                text:
                    'Digital acoustic fingerprint generated via Chromaprint for automated AcoustID track identification and MusicBrainz metadata cross-referencing. ',
              ),
              TextSpan(
                text: algoText,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: algoColor,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),

          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Monospace Fingerprint Preview Box
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0F1D),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: StudioColors.cardBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: isLoading
                            ? const Text(
                                'loading...',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Color(0xFF64748B),
                                  fontFamily: 'monospace',
                                ),
                              )
                            : (fpString != null && fpString.isNotEmpty
                                  ? SelectableText(
                                      fpString,
                                      style: const TextStyle(
                                        fontSize: 9,
                                        fontFamily: 'monospace',
                                        color: Colors.white,
                                        height: 1.25,
                                      ),
                                      maxLines: fingerprintMaxLines,
                                    )
                                  : const Text(
                                      '--',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: StudioColors.textMuted,
                                        fontFamily: 'monospace',
                                      ),
                                    )),
                      ),
                      if (!isLoading &&
                          fpString != null &&
                          fpString.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 13),
                          color: StudioColors.accentCyan,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 24,
                            minHeight: 24,
                          ),
                          tooltip: 'Copy Fingerprint',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: fpString));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Chromaprint fingerprint copied to clipboard',
                                ),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Identify Track Button (Web API with cache protection against rebuilds)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: InkWell(
                      onTap:
                          (!isLoading &&
                              fpString != null &&
                              fpString.isNotEmpty &&
                              widget.analyzerController != null)
                          ? () {
                              showDialog(
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
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color:
                              (!isLoading &&
                                  fpString != null &&
                                  fpString.isNotEmpty)
                              ? StudioColors.accentCyan.withValues(alpha: 0.15)
                              : StudioColors.cardBorder.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color:
                                (!isLoading &&
                                    fpString != null &&
                                    fpString.isNotEmpty)
                                ? StudioColors.accentCyan.withValues(alpha: 0.5)
                                : StudioColors.cardBorder.withValues(
                                    alpha: 0.3,
                                  ),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.travel_explore,
                              size: 13,
                              color:
                                  (!isLoading &&
                                      fpString != null &&
                                      fpString.isNotEmpty)
                                  ? StudioColors.accentCyan
                                  : (isLoading
                                        ? const Color(0xFF64748B)
                                        : StudioColors.textMuted),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isLoading
                                  ? 'loading...'
                                  : (fpString != null && fpString.isNotEmpty
                                        ? 'IDENTIFY TRACK (AcoustID API)'
                                        : '--'),
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                                color:
                                    (!isLoading &&
                                        fpString != null &&
                                        fpString.isNotEmpty)
                                    ? StudioColors.accentCyan
                                    : (isLoading
                                          ? const Color(0xFF64748B)
                                          : StudioColors.textMuted),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0F1D),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: StudioColors.cardBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Column(
                    children: [
                      _buildPropertyRow(
                        'Raw Vector',
                        isLoading
                            ? 'loading...'
                            : (chromaprint != null
                                  ? '${chromaprint.raw.length} × 32-bit'
                                  : '--'),
                        isLoading,
                      ),
                      _buildPropertyRow(
                        'FP Length',
                        isLoading
                            ? 'loading...'
                            : (fpString != null && fpString.isNotEmpty
                                  ? '${fpString.length} chars'
                                  : '--'),
                        isLoading,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
