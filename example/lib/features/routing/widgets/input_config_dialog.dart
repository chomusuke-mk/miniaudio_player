import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';

/// Modal dialog editing per-device microphone capture gain, direct hardware
/// monitoring, and sidechain auto-ducking parameters for a given [device].
class InputConfigDialog extends StatefulWidget {
  /// Target capture device being configured.
  final AudioDevice device;

  /// Initial input routing and ducking configuration populated into controls.
  final AudioInputConfig initialConfig;

  /// Callback invoked with the updated [AudioInputConfig] when saving changes.
  final Future<void> Function(AudioInputConfig config) onApply;

  /// Creates an [InputConfigDialog] editing [initialConfig] for [device] and
  /// invoking [onApply] upon confirmation.
  const InputConfigDialog({
    super.key,
    required this.device,
    required this.initialConfig,
    required this.onApply,
  });

  @override
  State<InputConfigDialog> createState() => _InputConfigDialogState();
}

/// Holds transient slider and switch state inside [InputConfigDialog].
class _InputConfigDialogState extends State<InputConfigDialog> {
  /// Pending microphone input capture volume multiplier.
  late double _volume;

  /// Pending direct hardware monitoring pass-through toggle state.
  late bool _monitorDirect;

  /// Pending direct monitor bus volume multiplier.
  late double _monitorVolume;

  /// Pending sidechain speech auto-ducking enable state.
  late bool _duckingEnabled;

  /// Pending music bus attenuation level in decibels during ducking.
  late double _duckingDb;

  /// Pending voice activity detector trigger threshold in decibels.
  late double _thresholdDb;

  /// Envelope attack duration in milliseconds preserved across edits.
  late double _attackMs;

  /// Envelope hold duration in milliseconds preserved across edits.
  late double _holdMs;

  /// Envelope release duration in milliseconds preserved across edits.
  late double _releaseMs;

  @override
  void initState() {
    super.initState();
    final cfg = widget.initialConfig;
    _volume = cfg.volume;
    _monitorDirect = cfg.monitorDirect;
    _monitorVolume = cfg.monitorVolume;
    _duckingEnabled = cfg.ducking?.enabled ?? false;
    _duckingDb = cfg.ducking?.duckingDb ?? -14.0;
    _thresholdDb = cfg.ducking?.thresholdDb ?? -30.0;
    _attackMs = cfg.ducking?.attackMs ?? 30.0;
    _holdMs = cfg.ducking?.holdMs ?? 250.0;
    _releaseMs = cfg.ducking?.releaseMs ?? 400.0;
  }

  /// Validates and persists the edited [AudioInputConfig] back to the caller.
  Future<void> _applyAndClose() async {
    final config = AudioInputConfig(
      volume: _volume,
      monitorDirect: _monitorDirect,
      monitorVolume: _monitorVolume,
      ducking: _duckingEnabled
          ? DuckingConfig(
              enabled: true,
              duckingDb: _duckingDb,
              thresholdDb: _thresholdDb,
              attackMs: _attackMs,
              holdMs: _holdMs,
              releaseMs: _releaseMs,
            )
          : null,
    );
    await widget.onApply(config);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StudioColors.cardBorder, width: 1.2),
      ),
      title: Row(
        children: [
          const Icon(Icons.settings, color: StudioColors.accentCyan, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Configure ${widget.device.displayName}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Capture Volume',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    '${(_volume * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 12,
                      color: StudioColors.accentCyan,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              Slider(
                value: _volume,
                min: 0.0,
                max: 2.0,
                activeColor: StudioColors.accentCyan,
                onChanged: (value) => setState(() => _volume = value),
              ),
              const Divider(color: StudioColors.cardBorder),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Direct Monitoring',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                subtitle: const Text(
                  'Pass-through input directly to master output mix',
                  style: TextStyle(fontSize: 10, color: StudioColors.textMuted),
                ),
                value: _monitorDirect,
                activeThumbColor: StudioColors.accentEmerald,
                onChanged: (value) => setState(() => _monitorDirect = value),
              ),
              if (_monitorDirect) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Monitor Volume',
                      style: TextStyle(
                        fontSize: 11,
                        color: StudioColors.textSecondary,
                      ),
                    ),
                    Text(
                      '${(_monitorVolume * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 11,
                        color: StudioColors.accentEmerald,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _monitorVolume,
                  min: 0.0,
                  max: 2.0,
                  activeColor: StudioColors.accentEmerald,
                  onChanged: (value) => setState(() => _monitorVolume = value),
                ),
              ],
              const Divider(color: StudioColors.cardBorder),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Microphone Auto-Ducking',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                subtitle: const Text(
                  'Sidechain attenuates music bus during speech',
                  style: TextStyle(fontSize: 10, color: StudioColors.textMuted),
                ),
                value: _duckingEnabled,
                activeThumbColor: StudioColors.accentAmber,
                onChanged: (value) => setState(() => _duckingEnabled = value),
              ),
              if (_duckingEnabled) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Ducking Attenuation',
                      style: TextStyle(
                        fontSize: 11,
                        color: StudioColors.textSecondary,
                      ),
                    ),
                    Text(
                      '${_duckingDb.toStringAsFixed(1)} dB',
                      style: const TextStyle(
                        fontSize: 11,
                        color: StudioColors.accentAmber,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _duckingDb,
                  min: -40.0,
                  max: 0.0,
                  activeColor: StudioColors.accentAmber,
                  onChanged: (value) => setState(() => _duckingDb = value),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Trigger Threshold',
                      style: TextStyle(
                        fontSize: 11,
                        color: StudioColors.textSecondary,
                      ),
                    ),
                    Text(
                      '${_thresholdDb.toStringAsFixed(1)} dB',
                      style: const TextStyle(
                        fontSize: 11,
                        color: StudioColors.accentAmber,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _thresholdDb,
                  min: -60.0,
                  max: -10.0,
                  activeColor: StudioColors.accentAmber,
                  onChanged: (value) => setState(() => _thresholdDb = value),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Attack / Hold / Release (ms)',
                      style: TextStyle(
                        fontSize: 10,
                        color: StudioColors.textMuted,
                      ),
                    ),
                    Text(
                      '${_attackMs.round()} / ${_holdMs.round()} / ${_releaseMs.round()} ms',
                      style: const TextStyle(
                        fontSize: 10,
                        color: StudioColors.accentAmber,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Cancel',
            style: TextStyle(color: StudioColors.textMuted),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: StudioColors.accentCyan,
            foregroundColor: Colors.black,
          ),
          onPressed: _applyAndClose,
          child: const Text(
            'Apply',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

/// No-op input configuration apply callback safe for constant widget previews.
Future<void> _noopApplyInputConfig(AudioInputConfig _) async {}

/// Preview rendering [InputConfigDialog] with monitoring and auto-ducking enabled.
@StudioPreview(
  name: 'Input Configuration Dialog',
  group: 'Routing',
  size: Size(500, 560),
)
Widget inputConfigDialogPreview() {
  return InputConfigDialog(
    device: StudioPreviewData.sampleInputDevices.first,
    initialConfig: const AudioInputConfig(
      volume: 1.0,
      monitorDirect: true,
      monitorVolume: 0.8,
      ducking: DuckingConfig(
        enabled: true,
        duckingDb: -14.0,
        thresholdDb: -30.0,
        attackMs: 30.0,
        holdMs: 250.0,
        releaseMs: 400.0,
      ),
    ),
    onApply: _noopApplyInputConfig,
  );
}
