import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../controllers/audio_analyzer_controller.dart';
import '../../models/acoustid_result.dart';
import '../../theme/studio_colors.dart';
import 'studio_badge.dart';

/// Modal dialog performing online AcoustID fingerprint lookup,
/// displaying ranked MusicBrainz acoustic matches with session-level caching.
class AcoustIdLookupDialog extends StatefulWidget {
  final String fingerprint;
  final double durationSeconds;
  final String trackTitle;
  final AudioAnalyzerController analyzerController;

  const AcoustIdLookupDialog({
    super.key,
    required this.fingerprint,
    required this.durationSeconds,
    required this.trackTitle,
    required this.analyzerController,
  });

  @override
  State<AcoustIdLookupDialog> createState() => _AcoustIdLookupDialogState();
}

class _AcoustIdLookupDialogState extends State<AcoustIdLookupDialog> {
  late Future<AcoustIdLookupResult> _future;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    setState(() {
      _future = widget.analyzerController.lookupAcoustId(
        fingerprint: widget.fingerprint,
        durationSeconds: widget.durationSeconds,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0A0E1A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StudioColors.cardBorder, width: 1.2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 720,
          maxHeight: 650,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Modal Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF0F172A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
                border: Border(bottom: BorderSide(color: StudioColors.cardBorder)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.fingerprint,
                    color: StudioColors.accentCyan,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ACOUSTID TRACK IDENTIFICATION',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Acoustic match for "${widget.trackTitle}" via AcoustID & MusicBrainz API',
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: StudioColors.textMuted,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: StudioColors.textMuted,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Modal Body
            Expanded(
              child: FutureBuilder<AcoustIdLookupResult>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              valueColor: AlwaysStoppedAnimation<Color>(StudioColors.accentCyan),
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Querying AcoustID open database...',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Searching acoustic fingerprint (${widget.durationSeconds.round()}s duration)',
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: StudioColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  final result = snapshot.data;
                  if (result == null || !result.success) {
                    final errorText = result?.errorMessage ?? 'Unknown error occurred while contacting AcoustID';
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: StudioColors.accentAmber,
                              size: 36,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Identification Failed',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              errorText,
                              style: const TextStyle(
                                fontSize: 10,
                                color: StudioColors.textMuted,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 14),
                            TextButton.icon(
                              onPressed: _fetch,
                              icon: const Icon(Icons.refresh, size: 14),
                              label: const Text('Retry Lookup', style: TextStyle(fontSize: 10)),
                              style: TextButton.styleFrom(
                                foregroundColor: StudioColors.accentCyan,
                                backgroundColor: const Color(0xFF0F172A),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  final matches = result.matches;
                  if (matches.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.search_off,
                              color: StudioColors.textMuted,
                              size: 36,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'No Acoustic Matches Found',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'This audio track has not yet been registered or indexed in the AcoustID / MusicBrainz open database.',
                              style: TextStyle(
                                fontSize: 10,
                                color: StudioColors.textMuted,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            if (result.isFromCache) ...[
                              const SizedBox(height: 10),
                              const StudioBadge(
                                label: 'CACHED IN-MEMORY',
                                color: StudioColors.accentCyan,
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: matches.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final match = matches[index];
                      return _buildMatchCard(match, result.isFromCache);
                    },
                  );
                },
              ),
            ),

            // Modal Footer: Fingerprint summary & Close
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(0xFF070B14),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
                border: Border(top: BorderSide(color: StudioColors.cardBorder)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ACOUSTIC FINGERPRINT HASH',
                          style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: StudioColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.fingerprint.length > 36
                              ? '${widget.fingerprint.substring(0, 36)}...'
                              : widget.fingerprint,
                          style: const TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 14),
                    color: StudioColors.accentCyan,
                    tooltip: 'Copy Fingerprint',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: widget.fingerprint));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Chromaprint copied to clipboard'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1E293B),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    ),
                    child: const Text('Close', style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMatchCard(AcoustIdMatch match, bool isFromCache) {
    final pctScore = (match.score * 100).round();
    final recordings = match.recordings;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Match Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF131D33),
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
              border: Border(bottom: BorderSide(color: StudioColors.cardBorder)),
            ),
            child: Row(
              children: [
                StudioBadge(
                  label: '$pctScore% MATCH',
                  color: pctScore >= 90
                      ? StudioColors.accentEmerald
                      : (pctScore >= 70 ? StudioColors.accentCyan : StudioColors.accentAmber),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AcoustID: ${match.id}',
                    style: const TextStyle(
                      fontSize: 9,
                      fontFamily: 'monospace',
                      color: StudioColors.textMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isFromCache)
                  const StudioBadge(
                    label: 'CACHED',
                    color: StudioColors.accentPurple,
                  ),
              ],
            ),
          ),

          // Recordings list inside this match cluster
          if (recordings.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12.0),
              child: Text(
                'Acoustic cluster recognized, but no associated MusicBrainz recording metadata found.',
                style: TextStyle(fontSize: 9.5, color: StudioColors.textMuted),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                children: recordings.map((rec) {
                  final artistsStr = rec.artists.isNotEmpty ? rec.artists.join(', ') : 'Unknown Artist';
                  final rgs = rec.releaseGroups;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090D18),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: StudioColors.cardBorder.withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.music_note, size: 13, color: StudioColors.accentCyan),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                rec.title.isNotEmpty ? rec.title : 'Untitled Recording',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Padding(
                          padding: const EdgeInsets.only(left: 19),
                          child: Text(
                            artistsStr,
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: StudioColors.accentEmerald,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (rgs.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.only(left: 19),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: rgs.map((rg) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: StudioColors.accentPurple.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(3),
                                    border: Border.all(
                                      color: StudioColors.accentPurple.withValues(alpha: 0.3),
                                      width: 0.6,
                                    ),
                                  ),
                                  child: Text(
                                    '${rg.title}${rg.type != null ? " (${rg.type})" : ""}',
                                    style: const TextStyle(
                                      fontSize: 8.5,
                                      color: StudioColors.accentPurple,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}
