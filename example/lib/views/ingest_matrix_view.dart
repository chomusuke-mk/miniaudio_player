import 'package:flutter/material.dart';
import '../../theme/studio_colors.dart';
import '../widgets/common/studio_badge.dart';
import '../widgets/common/studio_card.dart';

class IngestMatrixView extends StatelessWidget {
  const IngestMatrixView({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 5-Level Capability Promotion Card
        StudioCard(
          icon: Icons.layers,
          title: '5-LEVEL CAPABILITY PROMOTION HIERARCHY',
          subtitle: 'UriCapabilityResolver • Zero Overhead Direct Source Normalization',
          trailing: const StudioBadge(
            label: 'Universal Ingest',
            color: StudioColors.accentCyan,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPromotionLevel(
                level: 'LEVEL 1',
                title: 'FileAudioSource',
                scheme: 'file:// or POSIX / C:\\',
                desc: 'Direct OS filesystem path. Zero memory copy, kernel page cache DMA.',
                color: StudioColors.accentCyan,
              ),
              _buildPromotionLevel(
                level: 'LEVEL 2',
                title: 'MemoryAudioSource',
                scheme: 'data: URI or Uint8List RAM',
                desc: 'Direct memory buffer. Zero-copy sublist views with sub-microsecond seeking.',
                color: StudioColors.accentPurple,
              ),
              _buildPromotionLevel(
                level: 'LEVEL 3',
                title: 'AssetAudioSource',
                scheme: 'asset:// or package:...',
                desc: 'Flutter asset bundle bridged via MiniaudioPlayerGlobalConfig.assetLoader.',
                color: StudioColors.accentEmerald,
              ),
              _buildPromotionLevel(
                level: 'LEVEL 4A',
                title: 'NetworkAudioSource',
                scheme: 'http:// or https:// (VOD)',
                desc: 'Progressive HTTP byte-range client (Range: bytes=X-Y) with reactive backpressure.',
                color: StudioColors.accentBlue,
              ),
              _buildPromotionLevel(
                level: 'LEVEL 4B',
                title: 'LiveStreamAudioSource',
                scheme: 'icy:// or unbounded stream',
                desc: 'Sliding-window jitter buffer with on-the-fly Shoutcast metadata demuxing.',
                color: StudioColors.accentRose,
              ),
              _buildPromotionLevel(
                level: 'LEVEL 5',
                title: 'FdByteProvider / ResolvingAudioSource',
                scheme: 'content:// or /proc/self/fd/',
                desc: 'Android Scoped Storage optimization directly streaming open OS file descriptors.',
                color: StudioColors.accentAmber,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 2. Native Tripartite Memory Buffer Layout
        StudioCard(
          icon: Icons.memory,
          title: 'NATIVE TRIPARTITE BUFFER ARCHITECTURE (map_buffer_t)',
          subtitle: 'Separates Audio Bitstream Ingest from Consumer Codecs',
          trailing: const StudioBadge(
            label: 'O(1) Ring Buffer',
            color: StudioColors.accentEmerald,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: StudioColors.cardBorder, width: 1.2),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Container(
                        decoration: BoxDecoration(
                          color: StudioColors.accentCyan.withValues(alpha: 0.25),
                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(5)),
                        ),
                        child: const Center(
                          child: Text(
                            '1. Pinned Head\n(Headers & ID3v2)',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 6,
                      child: Container(
                        color: StudioColors.accentViolet.withValues(alpha: 0.20),
                        child: const Center(
                          child: Text(
                            '2. Pure Audio Ring Buffer\n(Sliding Frame Window)',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Container(
                        decoration: BoxDecoration(
                          color: StudioColors.accentAmber.withValues(alpha: 0.25),
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(5)),
                        ),
                        child: const Center(
                          child: Text(
                            '3. Tail Buffer\n(moov atom & ID3v1)',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '• Pinned Head: Nunca se sobreescribe; permite a decodificadores releer tablas de muestras.\n'
                '• Pure Audio Ring: Modular indexado circular; descarta datos tras el cursor y absorbe fluctuaciones.\n'
                '• Tail Buffer: Sonda final (probeTail) para archivos MP4 con átomos moov al final sin descargar todo el archivo.',
                style: TextStyle(fontSize: 10, color: StudioColors.textSecondary, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPromotionLevel({
    required String level,
    required String title,
    required String scheme,
    required String desc,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF0A0F1D),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: StudioColors.cardBorder, width: 1.0),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                level,
                style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w900, color: color),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: StudioColors.textPrimary),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '($scheme)',
                        style: TextStyle(fontSize: 9.5, color: color, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: const TextStyle(fontSize: 9, color: StudioColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
