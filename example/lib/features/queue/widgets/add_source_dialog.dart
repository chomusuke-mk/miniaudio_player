import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/models/audio_track.dart';
import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';

/// Modal dialog allowing users to add custom HTTP(S), `icy://`, `asset://`,
/// local file, OPFS path (Web), or `data:` audio URIs to the live queue.
class AddSourceDialog extends StatefulWidget {
  /// Invoked with the constructed [AudioTrack] before dismissing the dialog.
  final ValueChanged<AudioTrack> onTrackAdded;

  /// Creates an [AddSourceDialog] invoking [onTrackAdded] when confirmed.
  const AddSourceDialog({super.key, required this.onTrackAdded});

  @override
  State<AddSourceDialog> createState() => _AddSourceDialogState();
}

/// Manages text input controllers and URI submission inside [AddSourceDialog].
class _AddSourceDialogState extends State<AddSourceDialog> {
  /// Controller for the target audio URI or OPFS file path input field.
  final TextEditingController _urlController = TextEditingController();

  /// Controller for the optional custom display title input field.
  final TextEditingController _titleController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  /// Validates the entered URI, emits the new [AudioTrack], and pops the modal.
  void _submit() {
    final uriStr = _urlController.text.trim();
    if (uriStr.isEmpty) return;

    final title = _titleController.text.trim().isEmpty
        ? uriStr.split(RegExp(r'[/\\]')).last
        : _titleController.text.trim();

    final source = AudioSource(uriStr);
    final track = AudioTrack(
      id: uriStr,
      title: title,
      source: source,
      artist: 'Custom Ingest Source',
    );

    widget.onTrackAdded(track);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: StudioColors.cardBackgroundDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: StudioColors.cardBorder, width: 1.2),
      ),
      title: const Text(
        'Add Audio Source',
        style: TextStyle(color: StudioColors.textPrimary, fontSize: 16),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              kIsWeb
                  ? 'Supports Web OPFS paths (e.g. recordings/take.wav or /1.wav), '
                        'HTTP(S), icy:// (Live Streams), asset://, and data: URI.'
                  : 'Supports HTTP(S), icy:// (Live Streams), local paths, file://, asset://, and data: URI.',
              style: const TextStyle(
                color: StudioColors.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: kIsWeb
                    ? 'Audio URI, URL, or OPFS Path'
                    : 'Audio URI or URL',
                hintText: kIsWeb
                    ? 'recordings/take.wav, https://..., or asset://...'
                    : 'https://... or icy://... or file://...',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Optional Title',
                hintText: 'My Audio',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: StudioColors.accentCyan,
            foregroundColor: Colors.black,
          ),
          onPressed: _submit,
          child: const Text('Add & Play'),
        ),
      ],
    );
  }
}

/// No-op track addition callback safe for constant widget previews.
void _noopTrackAdded(AudioTrack _) {}

/// Preview rendering [AddSourceDialog] for custom source URI entry.
@StudioPreview(
  name: 'Add Audio Source Dialog',
  group: 'Queue',
  size: Size(440, 320),
)
Widget addSourceDialogPreview() {
  return const AddSourceDialog(onTrackAdded: _noopTrackAdded);
}
