import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_metric_tile.dart';

/// Pure sub-section presenting Chromaprint acoustic fingerprint data,
/// copy-to-clipboard shortcut, raw vector length metrics, and an external
/// identification button callback.
class AnalyzerFingerprintSection extends StatelessWidget {
  /// Extracted Chromaprint fingerprint result, or `null` when unavailable.
  final ChromaprintResult? chromaprint;

  /// Whether acoustic analysis is currently active.
  final bool isLoading;

  /// Maximum display lines shown for the selectable fingerprint box.
  final int fingerprintMaxLines;

  /// Invoked when clicking `IDENTIFY TRACK (AcoustID API)`. Pass `null` when
  /// identification is unavailable.
  final VoidCallback? onIdentifyTrack;

  /// Creates an [AnalyzerFingerprintSection] rendering [chromaprint] with
  /// [isLoading] placeholder state, [fingerprintMaxLines] cap, and
  /// [onIdentifyTrack] action handler.
  const AnalyzerFingerprintSection({
    super.key,
    required this.chromaprint,
    this.isLoading = false,
    this.fingerprintMaxLines = 2,
    this.onIdentifyTrack,
  });

  @override
  Widget build(BuildContext context) {
    final fpString = chromaprint?.fingerprint;
    final algorithm = chromaprint?.algorithm;
    final hasFingerprint =
        !isLoading && fpString != null && fpString.isNotEmpty;

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
          StudioSubCardHeader(
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
                            : (hasFingerprint
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
                      if (hasFingerprint) ...[
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: InkWell(
                      onTap: hasFingerprint ? onIdentifyTrack : null,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: hasFingerprint
                              ? StudioColors.accentCyan.withValues(alpha: 0.15)
                              : StudioColors.cardBorder.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: hasFingerprint
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
                              color: hasFingerprint
                                  ? StudioColors.accentCyan
                                  : (isLoading
                                        ? const Color(0xFF64748B)
                                        : StudioColors.textMuted),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isLoading
                                  ? 'loading...'
                                  : (hasFingerprint
                                        ? 'IDENTIFY TRACK (AcoustID API)'
                                        : '--'),
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                                color: hasFingerprint
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
                      StudioPropertyRow(
                        label: 'Raw Vector',
                        value: isLoading
                            ? 'loading...'
                            : (chromaprint != null
                                  ? '${chromaprint!.raw.length} × 32-bit'
                                  : '--'),
                        isLoading: isLoading,
                      ),
                      StudioPropertyRow(
                        label: 'FP Length',
                        value: isLoading
                            ? 'loading...'
                            : (fpString != null && fpString.isNotEmpty
                                  ? '${fpString.length} chars'
                                  : '--'),
                        isLoading: isLoading,
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

/// Preview rendering [AnalyzerFingerprintSection] with sample Chromaprint hash.
@StudioPreview(
  name: 'Analyzer Fingerprint Section',
  group: 'Analyzer',
  size: Size(300, 320),
)
Widget analyzerFingerprintSectionPreview() {
  return AnalyzerFingerprintSection(
    chromaprint: StudioPreviewData.sampleChromaprint,
    onIdentifyTrack: StudioPreviewData.noopVoid,
  );
}
