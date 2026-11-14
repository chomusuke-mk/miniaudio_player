import 'package:flutter/material.dart';

import '../../theme/studio_colors.dart';
import '../widgets/common/responsive_grid.dart';
import '../widgets/common/studio_badge.dart';
import '../widgets/common/studio_card.dart';

/// Displays the live v4.0.0 Rust ingest, `IoWorkerPool`, three-plane `StreamSession`,
/// progressive sliding-window coalescing, and downstream wait-free RT pipeline.
class IngestMatrixView extends StatelessWidget {
  const IngestMatrixView({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Row 1: ByteSource Routing & IoWorkerPool + 3-Plane StreamSession
        ResponsiveGrid(
          leftFlex: 1,
          rightFlex: 1,
          leftColumn: [
            StudioCard(
              icon: Icons.layers_outlined,
              title: 'BYTESOURCE ROUTING & IO WORKER POOL',
              subtitle:
                  'AudioSource<T> -> ByteSource Hierarchy • Dedicated Local & Coalesced Network Lanes',
              subtitleMaxLines: 2,
              trailing: const StudioBadge(
                label: 'Rust Native IO',
                color: StudioColors.accentCyan,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStageTile(
                    tag: 'LOCAL',
                    title: 'FileByteSource (map-io-local)',
                    badge: 'file:// • asset:// • POSIX / Win • 64 KB BufReader',
                    desc:
                        'Direct OS filesystem reader on the zero-delay local worker lane (including stripped asset:// paths). Loads the 64 KB header window plus container tail tags directly into StreamSession.',
                    color: StudioColors.accentCyan,
                  ),
                  _buildStageTile(
                    tag: 'MEMORY',
                    title: 'MemoryByteSource (Zero-Dupe Handoff)',
                    badge: 'Uint8List • List<int> • data: URI',
                    desc:
                        'Transfers byte ownership into native Rust memory (e.g. from rootBundle.load or raw PCM/encoded bytes) and clears the Dart heap reference via _clearBytes(). Sub-microsecond in-RAM seeking.',
                    color: StudioColors.accentPurple,
                  ),
                  _buildStageTile(
                    tag: 'NET VOD',
                    title: 'StreamByteSource (4x map-io-net Workers)',
                    badge: 'http:// • https:// • Range + Epoch',
                    desc:
                        'ureq TLS client using HTTP Range requests. Coalesces rapid Next/Prev track skipping (18 ms quiet / 140 ms burst cap) and cancels stale loads via CancelToken.',
                    color: StudioColors.accentBlue,
                  ),
                  _buildStageTile(
                    tag: 'LIVE / HLS',
                    title: 'StreamByteSource (ICY + HLS AES-128)',
                    badge: 'icy:// • .m3u8 • MPEG-TS • CBC',
                    desc:
                        'Sliding-window live radio ingest with inline ICY metadata demuxing, plus m3u8-rs HLS playlist parsing, AES-128-CBC segment decryption, and MPEG-TS demux.',
                    color: StudioColors.accentRose,
                  ),
                  _buildStageTile(
                    tag: 'CUSTOM',
                    title: 'CustomDartByteSource (Pull Bridge)',
                    badge: 'custom://<streamId> • CustomByteProvider',
                    desc:
                        'CustomSourceRegistry requests >= 32 KB on-demand prefetches from async Dart streams (10 s timeout, zero disk files) straight into StreamSession.',
                    color: StudioColors.accentEmerald,
                    isLast: true,
                  ),
                ],
              ),
            ),
          ],
          rightColumn: [
            StudioCard(
              icon: Icons.memory_outlined,
              title: '3-PLANE STREAMSESSION & DEMUX BRIDGE',
              subtitle:
                  'StreamClassifier Routing • Head / Body / Metadata Decoupling into Symphonia & Lofty',
              subtitleMaxLines: 2,
              trailing: const StudioBadge(
                label: 'Zero Contention',
                color: StudioColors.accentEmerald,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSessionMemoryStrip(),
                  const SizedBox(height: 12),
                  _buildStageTile(
                    tag: 'PLANE 1',
                    title: 'Head (BufferBackend::Linear)',
                    badge: '>= 64 KB Init • 32 KB Growth Step',
                    desc:
                        'Pins container headers (moov, fLaC, OpusHead, RIFF, ID3 lead-in) in linear RAM so decoder re-probes and instant seek-to-zero never re-fetch.',
                    color: StudioColors.accentCyan,
                  ),
                  _buildStageTile(
                    tag: 'PLANE 2',
                    title: 'Body (BufferBackend::Circular)',
                    badge: '8 MB Ring Cap • [B_back | B_ahead]',
                    desc:
                        'Sliding ring anchored at audio_start..audio_end. Preserves backward seek history (10 s local / 15 s net) and lookahead (30 s, 1x–3x rate-scaled).',
                    color: StudioColors.accentBlue,
                  ),
                  _buildStageTile(
                    tag: 'PLANE 3',
                    title: 'Metadata (BufferBackend::Sparse)',
                    badge: 'BTreeMap<u64, Vec<u8>>',
                    desc:
                        'Sparse offset store isolating ID3v1/v2, Vorbis, APEv2, MP4 ilst, chapters, cover art, and live ICY updates out of the audio ring buffer.',
                    color: StudioColors.accentPurple,
                  ),
                  _buildStageTile(
                    tag: 'BRIDGE',
                    title: 'DemuxedStreamReader & Standby Prewarm',
                    badge: 'Symphonia 0.6 • PrewarmJob',
                    desc:
                        'Presents Head + Body as one unified std::io::Read + Seek + MediaSource to Symphonia & Lofty, while IoWorkerPool pre-warms standby deck headers.',
                    color: StudioColors.accentEmerald,
                    isLast: true,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Row 2: Progressive Sliding-Window Coalescing + Downstream RT Pipeline
        ResponsiveGrid(
          leftFlex: 1,
          rightFlex: 1,
          leftColumn: [
            StudioCard(
              icon: Icons.bolt_outlined,
              title: '3-PHASE SLIDING-WINDOW COALESCING',
              subtitle:
                  'BlockFetchPhase FSM • Exponential Burst Amortization & Seek Re-Anchoring',
              subtitleMaxLines: 2,
              trailing: const StudioBadge(
                label: 'SlidingWindowConfig',
                color: StudioColors.accentAmber,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStageTile(
                    tag: 'PHASE 1',
                    title: 'UrgentBootstrap (< 1x B_win Buffered)',
                    badge: 'Immediate 5 s Fetch • Min TTFB',
                    desc:
                        'When lookahead drops below one 5 s window (32 KB/s floor bitrate scaled dynamically by playback rate), requests 1x B_win immediately for fast startup.',
                    color: StudioColors.accentRose,
                  ),
                  _buildStageTile(
                    tag: 'PHASE 2',
                    title: 'Stabilization (1x..3x B_win Buffered)',
                    badge: 'Incremental 5 s Windows',
                    desc:
                        'Streams steady single-window increments to prevent underruns during bitrate stabilization before switching into coarse cruise batching.',
                    color: StudioColors.accentAmber,
                  ),
                  _buildStageTile(
                    tag: 'PHASE 3',
                    title: 'CoalescedCruise (>= 15 s Buffered)',
                    badge: '3x B_win Super-Blocks',
                    desc:
                        'Pauses HTTP requests until a 3x window (15 s) deficit builds up, merging multiple tiny reads into one coalesced HTTP Range transfer.',
                    color: StudioColors.accentEmerald,
                  ),
                  _buildStageTile(
                    tag: 'SEEK',
                    title: 'In-Window RAM Hit & Epoch Re-Anchor',
                    badge: 'O(1) Local Hit • Range Re-Anchor',
                    desc:
                        'Seeks inside [B_back, B_ahead] jump instantaneously in RAM with zero network I/O. Out-of-window seeks call reset_for_seek and fetch a fresh Range block.',
                    color: StudioColors.accentCyan,
                    isLast: true,
                  ),
                ],
              ),
            ),
          ],
          rightColumn: [
            StudioCard(
              icon: Icons.graphic_eq_outlined,
              title: 'DOWNSTREAM DECODE -> DSP -> 5-BUS SPSC MATRIX',
              subtitle:
                  'Wait-Free rtrb Rings • Dual-Deck Crossfade & Physical Endpoint Deduplication',
              subtitleMaxLines: 2,
              trailing: const StudioBadge(
                label: 'Zero Mutex RT',
                color: StudioColors.accentPurple,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStageTile(
                    tag: 'DECODE',
                    title: 'Symphonia + Custom Codecs -> Rubato',
                    badge: 'SilenceDetector -> Matrix -> rtrb',
                    desc:
                        'Decodes MP3, FLAC, Opus, FDK-AAC, APE, WavPack, DSF & Extended PCM through SilenceDetector, ChannelMatrix, and Rubato resampler into SPSC ring buffers.',
                    color: StudioColors.accentCyan,
                  ),
                  _buildStageTile(
                    tag: 'DECK RT',
                    title: 'Per-Deck AudioRenderer & DspChain',
                    badge: 'SonicStream + ReplayGain + BS2B',
                    desc:
                        'Deck A & Deck B independently run Sonic time/pitch scaling, 3D Spatial Doppler kinematics, BS2B crossfeed, and per-track ReplayGain prior to crossfade.',
                    color: StudioColors.accentBlue,
                  ),
                  _buildStageTile(
                    tag: 'MIXER',
                    title: 'Master Mix, Auto-Ducker & 64-Voice SFX',
                    badge: 'DspProcessor + SimdMixer (AVX2/NEON)',
                    desc:
                        'Applies EqualPower/Linear crossfades, shared EQ/Reverb, multi-mic RMS AutoDucker sidechain, 64 SFX voices (Inherit/Isolate/Bypass), and soft-clip limiting.',
                    color: StudioColors.accentPurple,
                  ),
                  _buildStageTile(
                    tag: 'DISPATCH',
                    title: '5-Bus Output, Recorder & Seqlock FFT',
                    badge: 'All • MusicMix • Active • Standby • Voice',
                    desc:
                        'Single-owner map-engine-clock feeds deduplicated physical sinks via rtrb, WavRecorder (Pcm16/Float32), and Lock-Free 10-Band FFT Visualizer (CachePaddedSeqlock).',
                    color: StudioColors.accentEmerald,
                    isLast: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSessionMemoryStrip() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Container(
                      color: StudioColors.accentCyan.withValues(alpha: 0.24),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'HEAD (Linear)',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: StudioColors.accentCyan,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(width: 1, color: const Color(0xFF334155)),
                  Expanded(
                    flex: 5,
                    child: Container(
                      color: StudioColors.accentBlue.withValues(alpha: 0.24),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'BODY SLIDING RING (B_back | B_ahead)',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: StudioColors.accentBlue,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(width: 1, color: const Color(0xFF334155)),
                  Expanded(
                    flex: 2,
                    child: Container(
                      color: StudioColors.accentPurple.withValues(alpha: 0.24),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'META (Sparse)',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: StudioColors.accentPurple,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _buildLegendChip('Head >= 64 KB', StudioColors.accentCyan),
              _buildLegendChip('Body Cap 8 MB (10s/30s)', StudioColors.accentBlue),
              _buildLegendChip('Metadata BTreeMap', StudioColors.accentPurple),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegendChip(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              color: StudioColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStageTile({
    required String tag,
    required String title,
    required String badge,
    required String desc,
    required Color color,
    bool isLast = false,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: isLast ? 0 : 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: color.withValues(alpha: 0.45)),
                ),
                child: Text(
                  tag,
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w900,
                    color: color,
                    fontFamily: 'monospace',
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: StudioColors.textPrimary,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            desc,
            style: const TextStyle(
              fontSize: 10.5,
              color: StudioColors.textSecondary,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
