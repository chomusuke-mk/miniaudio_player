import 'miniaudio_player.dart';

/// Represents an audio device (playback or capture).
class AudioDevice {
  /// Unique device identifier (hex-encoded string for hardware devices, or 'auto' for automatic default).
  final String id;

  /// Underlying physical hardware device endpoint ID currently active in the OS.
  final String effectiveId;

  /// Human-readable device name or 'SYSTEM DEFAULT'.
  final String name;

  /// Underlying hardware device name currently routed by the operating system (when [isAuto] is true).
  final String? _resolvedName;

  /// Whether this device represents the automatic system-managed output.
  final bool _isAuto;

  /// Optional hardware device type code (e.g. Android AudioDeviceInfo.type).
  final int? type;

  const AudioDevice({
    required this.id,
    this.effectiveId = '',
    required this.name,
    String? resolvedName,
    bool isAuto = false,
    this.type,
  })  : _resolvedName = resolvedName,
        _isAuto = isAuto || id == 'auto' || id == '';

  /// Hardware device name currently routed by the OS (when [isAuto] is true).
  String? get resolvedName => _resolvedName;

  /// Whether this device represents the automatic system-managed output.
  bool get isAuto => _isAuto;

  /// Automatic / system-managed default output audio device template.
  static const AudioDevice auto = AudioDevice(
    id: 'auto',
    effectiveId: '',
    name: 'SYSTEM DEFAULT',
    isAuto: true,
  );

  /// User-friendly display name.
  ///
  /// Uses [MiniaudioPlayerGlobalConfig.defaultDeviceDisplayNameResolver] if this
  /// device is [isAuto], otherwise returns [name] directly.
  String get displayName {
    if (isAuto) {
      final cleanResolved = _resolvedName?.trim();
      if (cleanResolved != null && cleanResolved.isNotEmpty) {
        return MiniaudioPlayer.globalConfig
            .defaultDeviceDisplayNameResolver(cleanResolved);
      }
      return 'System Default';
    }
    return name;
  }

  /// Compares whether two devices route to the same underlying physical hardware endpoint.
  bool isSameEndpoint(AudioDevice other) {
    if (effectiveId.isNotEmpty && other.effectiveId.isNotEmpty) {
      return effectiveId == other.effectiveId;
    }
    return id == other.id;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AudioDevice) return false;
    if (isAuto && other.isAuto) return true;
    return id == other.id;
  }

  @override
  int get hashCode => isAuto ? 'auto'.hashCode : id.hashCode;

  @override
  String toString() =>
      'AudioDevice(id: $id, name: $name, isAuto: $isAuto, effectiveId: $effectiveId${type != null ? ', type: $type' : ''})';
}
