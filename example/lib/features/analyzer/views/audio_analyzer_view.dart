import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/models/audio_track.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/responsive_grid.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_card.dart';
import '../../../shared/widgets/studio_metric_tile.dart';
import '../../console/controllers/audio_engine_controller.dart';
import '../controllers/audio_analyzer_controller.dart';
import '../widgets/audio_analyzer_card.dart';

/// Dedicated Audio Analyzer tab view pairing live pipeline session telemetry
/// and queue track inspection with detailed [AudioAnalyzerCard] metrics and
/// Rust/Dart single-pass architecture cards.
class AudioAnalyzerView extends StatelessWidget {
  /// Primary audio engine controller providing available queue tracks and live
  /// selection state.
  final AudioEngineController playerController;

  /// Acoustic analyzer controller providing cached analysis outputs, timing
  /// metrics, and session statistics.
  final AudioAnalyzerController analyzerController;

  /// Creates an [AudioAnalyzerView] bound to [playerController] and
  /// [analyzerController].
  const AudioAnalyzerView({
    super.key,
    required this.playerController,
    required this.analyzerController,
  });

  /// Resolves the currently inspected [AudioTrack] from [tracks] using
  /// [AudioAnalyzerController.currentTrackId] or falling back to
  /// [AudioEngineController.selectedTrack].
  AudioTrack? _resolveInspectedTrack(List<AudioTrack> tracks) {
    final targetId =
        analyzerController.currentTrackId ?? playerController.selectedTrack?.id;
    if (targetId != null) {
      for (final track in tracks) {
        if (track.id == targetId) {
          return track;
        }
      }
    }
    return playerController.selectedTrack;
  }

  /// Formats the elapsed timing / cache-hit summary label for [track].
  String _formatLastPassLabel(AudioTrack? track) {
    if (track == null) return '--';
    if (!track.canAnalyze) return 'STREAM ONLY';
    if (analyzerController.isAnalyzingTrack(track)) return 'ANALYZING...';
    final ms = analyzerController.getDurationMsForTrack(track);
    if (analyzerController.wasLastServedFromCache(track)) {
      return ms != null ? '0 ms (Cache • ${ms}ms pass)' : '0 ms (Cache HIT)';
    }
    if (ms != null) {
      return '$ms ms (1-Pass Native)';
    }
    return '--';
  }

  /// Builds an interactive track pill for [track] reflecting [isInspected],
  /// [isPlayingTrack], [isCached], and [isAnalyzing] state flags.
  Widget _buildTrackPill({
    required AudioTrack track,
    required bool isInspected,
    required bool isPlayingTrack,
    required bool isCached,
    required bool isAnalyzing,
  }) {
    final Color borderColor;
    final Color bgColor;
    if (isInspected) {
      borderColor = StudioColors.accentCyan;
      bgColor = StudioColors.accentCyan.withValues(alpha: 0.16);
    } else if (isCached) {
      borderColor = StudioColors.accentEmerald.withValues(alpha: 0.5);
      bgColor = const Color(0xFF0A0F1D);
    } else {
      borderColor = StudioColors.cardBorder;
      bgColor = const Color(0xFF0A0F1D);
    }

    final IconData statusIcon;
    final Color statusColor;
    if (isAnalyzing) {
      statusIcon = Icons.sync;
      statusColor = StudioColors.accentAmber;
    } else if (isPlayingTrack) {
      statusIcon = Icons.play_arrow_rounded;
      statusColor = StudioColors.accentCyan;
    } else if (isCached) {
      statusIcon = Icons.bolt;
      statusColor = StudioColors.accentEmerald;
    } else {
      statusIcon = track.canAnalyze ? Icons.audiotrack : Icons.wifi_tethering;
      statusColor = StudioColors.textMuted;
    }

    return Material(
      color: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: borderColor, width: isInspected ? 1.2 : 0.9),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          MapLogger.info(
            '[ANALYZER:UI] Track pill tapped: "${track.title}" (canAnalyze=${track.canAnalyze})',
          );
          analyzerController.selectTrack(track);
          if (track.canAnalyze) {
            unawaited(
              analyzerController.analyze(
                track,
                engine: playerController.engine,
              ),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(statusIcon, size: 13, color: statusColor),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  track.title,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: isInspected ? FontWeight.w700 : FontWeight.w500,
                    color: isInspected
                        ? StudioColors.accentCyan
                        : StudioColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds an optimization documentation stage row tagged with [tag], [title],
  /// [accentTag], [description], and tinted with [color].
  Widget _buildPipelineStageCard({
    required String tag,
    required String title,
    required String accentTag,
    required String description,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0A0F1D),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: StudioColors.cardBorder, width: 0.9),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: StudioColors.textPrimary,
                        ),
                      ),
                      Text(
                        '($accentTag)',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace',
                          color: color,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 9.5,
                      color: StudioColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: Listenable.merge([
            playerController.trackSelectionListenable,
            playerController.queueListenable,
            analyzerController,
          ]),
          builder: (context, _) {
            final tracks = playerController.availableTracks;
            final playingTrack = playerController.selectedTrack;
            final inspectedTrack = _resolveInspectedTrack(tracks);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StudioCard(
                  icon: Icons.speed_outlined,
                  title: 'ANALYSIS PIPELINE & SESSION TELEMETRY',
                  subtitle:
                      'Live Single-Pass Timing, Session Cache Efficiency & Coalesced Queue Control',
                  trailing: StudioBadge(
                    label: '${analyzerController.cachedTrackCount} CACHED',
                    color: analyzerController.cachedTrackCount > 0
                        ? StudioColors.accentEmerald
                        : StudioColors.textMuted,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          StudioMetricTile(
                            label: 'CACHED TRACKS',
                            value:
                                '${analyzerController.cachedTrackCount}/${tracks.length}',
                            color: StudioColors.accentEmerald,
                          ),
                          StudioMetricTile(
                            label: 'CACHE HITS',
                            value: '${analyzerController.cacheHits}',
                            color: StudioColors.accentCyan,
                          ),
                          StudioMetricTile(
                            label: '1-PASS DECODES',
                            value: '${analyzerController.freshAnalyses}',
                            color: StudioColors.accentPurple,
                          ),
                          StudioMetricTile(
                            label: 'COALESCED SKIPS',
                            value: '${analyzerController.coalescedSkips}',
                            color: StudioColors.accentAmber,
                          ),
                          StudioMetricTile(
                            label: 'ACTIVE PASS',
                            value: _formatLastPassLabel(inspectedTrack),
                            color: StudioColors.textPrimary,
                          ),
                        ],
                      ),
                      if (tracks.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        const Text(
                          'INSPECT QUEUE TRACK (TAP TO READ CACHE OR ANALYZE)',
                          style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color: StudioColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: tracks
                              .map(
                                (track) => _buildTrackPill(
                                  track: track,
                                  isInspected: track.id == inspectedTrack?.id,
                                  isPlayingTrack: track.id == playingTrack?.id,
                                  isCached: analyzerController
                                      .hasResultForTrack(track),
                                  isAnalyzing: analyzerController
                                      .isAnalyzingTrack(track),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                RepaintBoundary(
                  child: AudioAnalyzerCard(
                    track: inspectedTrack,
                    playerController: playerController,
                    analyzerController: analyzerController,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        ResponsiveGrid(
          leftFlex: 1,
          rightFlex: 1,
          leftColumn: [
            StudioCard(
              icon: Icons.bolt_outlined,
              title: 'SINGLE-PASS NATIVE PIPELINE (RUST DSP)',
              subtitle:
                  'Zero Duplicate Decoding Across Loudness, Waveform & Fingerprinting',
              trailing: const StudioBadge(
                label: '1 Decode Pass',
                color: StudioColors.accentCyan,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPipelineStageCard(
                    tag: 'STAGE 1',
                    title: 'Header & Container Fast-Path',
                    accentTag: '< 1 ms • Zero PCM Decode',
                    description:
                        'When ReplayGain, Waveform, and Chromaprint are disabled, native probing reads AudioInfo and container metadata tags straight from file headers without decoding sample frames.',
                    color: StudioColors.accentCyan,
                  ),
                  _buildPipelineStageCard(
                    tag: 'STAGE 2',
                    title: 'Livestream Guard Short-Circuit',
                    accentTag: 'deck.is_live_stream()',
                    description:
                        'Unbounded broadcasts (ICY / live radio) skip whole-track loudness, waveform, and fingerprint scans immediately, returning codec info and stream metadata with duration: null.',
                    color: StudioColors.accentRose,
                  ),
                  _buildPipelineStageCard(
                    tag: 'STAGE 3',
                    title: 'Unified PCM Pull Loop',
                    accentTag: 'analyze_audio_source',
                    description:
                        'One CPU pull loop feeds each decoded stereo frame simultaneously into BS.1770-4 K-weighting (1681.97 Hz HS + 38.14 Hz RLB biquads, 400 ms dual-gated LUFS to -18.0 LUFS target), 100-block waveform RMS, and Chromaprint (Algorithm::Test2).',
                    color: StudioColors.accentPurple,
                  ),
                  _buildPipelineStageCard(
                    tag: 'STAGE 4',
                    title: 'Zero-Churn Chromaprint Scratch Buffer',
                    accentTag: 'pcm_i16_buf reuse',
                    description:
                        'Converts decoded float chunks to 16-bit PCM inside a reusable pre-allocated Vec<i16> cleared in place between chunks, avoiding repeated heap allocations during fingerprinting.',
                    color: StudioColors.accentEmerald,
                  ),
                ],
              ),
            ),
          ],
          rightColumn: [
            StudioCard(
              icon: Icons.memory_outlined,
              title: 'MEMORY, WORKER & CACHING OPTIMIZATIONS',
              subtitle:
                  'O(1) Native Envelope Memory • Serial Queue Coalescing & Cache Deduplication',
              trailing: const StudioBadge(
                label: 'O(1) RAM',
                color: StudioColors.accentEmerald,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPipelineStageCard(
                    tag: 'OPT 1',
                    title: 'Dynamic 2:1 RMS Waveform Decimation',
                    accentTag: 'MAX_BUCKETS = 2048',
                    description:
                        'AdaptiveWaveformAccumulator begins at 256 frames/bucket. Reaching 2,048 buckets triggers pairwise quadratic RMS folding (sqrt((a² + b²) / 2)) and doubles frames_per_block, keeping memory under 16 KB even for 10+ hour tracks.',
                    color: StudioColors.accentEmerald,
                  ),
                  _buildPipelineStageCard(
                    tag: 'OPT 2',
                    title: 'Isolated Background Analysis Deck',
                    accentTag: 'new_analysis_deck',
                    description:
                        'Runs at maximum CPU throughput on an isolated offline StreamingDeck thread so real-time audio hardware callbacks and crossfades never suffer mutex contention or buffer dropouts.',
                    color: StudioColors.accentCyan,
                  ),
                  _buildPipelineStageCard(
                    tag: 'OPT 3',
                    title: 'Serial Worker & Track-Switch Coalescing',
                    accentTag: 'Latest-Wins Queue',
                    description:
                        'AudioAnalyzerController keeps only one active decode pass and replaces any unstarted pending request on rapid Next/Previous track changes, preventing redundant background decodes.',
                    color: StudioColors.accentAmber,
                  ),
                  _buildPipelineStageCard(
                    tag: 'OPT 4',
                    title: 'Session Cache & AcoustID Deduplication',
                    accentTag: '0 ms Revisits + Sync',
                    description:
                        'Completed results stay cached per track ID for instant revisits, synchronize ReplayGainConfig straight into engine.action.setReplayGain, and deduplicate concurrent AcoustID HTTP lookups.',
                    color: StudioColors.accentPurple,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
