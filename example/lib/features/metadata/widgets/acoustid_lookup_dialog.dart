import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/models/acoustid_result.dart';
import '../../analyzer/controllers/audio_analyzer_controller.dart';
import 'acoustid_lookup_body.dart';

/// Modal dialog performing online AcoustID fingerprint lookup via
/// [analyzerController] and rendering results through [AcoustIdLookupBody].
class AcoustIdLookupDialog extends StatefulWidget {
  /// Base64 Chromaprint hash submitted to AcoustID.
  final String fingerprint;

  /// Audio duration in seconds passed alongside [fingerprint].
  final double durationSeconds;

  /// Track title shown in the identification modal header.
  final String trackTitle;

  /// Analyzer controller providing AcoustID network calls and session caching.
  final AudioAnalyzerController analyzerController;

  /// Creates an [AcoustIdLookupDialog] querying AcoustID for [fingerprint] and
  /// [durationSeconds] on [analyzerController] for [trackTitle].
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

/// Manages the active AcoustID lookup [Future] and retry lifecycle.
class _AcoustIdLookupDialogState extends State<AcoustIdLookupDialog> {
  /// Pending or completed AcoustID lookup future rendered by the body widget.
  late Future<AcoustIdLookupResult> _future;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  /// Starts or retries the AcoustID lookup for the configured fingerprint.
  void _fetch() {
    MapLogger.debug(
      '[ACOUSTID:UI] Triggering lookup for "${widget.trackTitle}" (${widget.durationSeconds.round()}s)',
    );
    setState(() {
      _future = widget.analyzerController
          .lookupAcoustId(
            fingerprint: widget.fingerprint,
            durationSeconds: widget.durationSeconds,
          )
          .then((result) {
            if (!result.success) {
              MapLogger.warn(
                '[ACOUSTID:UI] Lookup failed for "${widget.trackTitle}": ${result.errorMessage}',
              );
            } else {
              MapLogger.info(
                '[ACOUSTID:UI] Lookup resolved ${result.matches.length} matches (cached=${result.isFromCache})',
              );
            }
            return result;
          });
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AcoustIdLookupResult>(
      future: _future,
      builder: (context, snapshot) {
        return AcoustIdLookupBody(
          fingerprint: widget.fingerprint,
          durationSeconds: widget.durationSeconds,
          trackTitle: widget.trackTitle,
          isLoading: snapshot.connectionState == ConnectionState.waiting,
          result: snapshot.data,
          onRetry: _fetch,
          onClose: () => Navigator.of(context).pop(),
        );
      },
    );
  }
}
