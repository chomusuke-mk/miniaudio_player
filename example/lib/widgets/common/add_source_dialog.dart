import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import '../../models/audio_track.dart';
import '../../theme/studio_colors.dart';

class AddSourceDialog extends StatefulWidget {
  final ValueChanged<AudioTrack> onTrackAdded;

  const AddSourceDialog({super.key, required this.onTrackAdded});

  @override
  State<AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<AddSourceDialog> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _submit() {
    final uriStr = _urlController.text.trim();
    if (uriStr.isEmpty) return;

    final title = _titleController.text.trim().isEmpty
        ? uriStr.split(RegExp(r'[/\\]')).last
        : _titleController.text.trim();

    final source = AudioSource.uri(uriStr);
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
            const Text(
              'Supports HTTP(S), icy:// (Live Streams), file://, asset://, and data: URI.',
              style: TextStyle(color: StudioColors.textSecondary, fontSize: 11),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Audio URI or URL',
                hintText: 'https://... or icy://... or file://...',
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
