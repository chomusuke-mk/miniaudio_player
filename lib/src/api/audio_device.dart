import 'miniaudio_player.dart';

/// Represents an audio device (playback or capture).
class AudioDevice {
  /// Unique device identifier (hex-encoded string for hardware devices, or `'auto'` for automatic default).
  final String id;

  /// Underlying physical hardware device endpoint ID currently active in the OS.
  final String effectiveId;

  /// Human-readable device name or `'SYSTEM DEFAULT'`.
  final String name;

  /// Underlying hardware device name currently routed by the operating system when [isAuto] is `true`.
  final String? _resolvedName;

  /// Whether this device represents the automatic system-managed output.
  final bool _isAuto;

  /// Optional hardware device type code (for example, Android `AudioDeviceInfo.type`).
  final int? type;

  /// Creates an [AudioDevice] descriptor with [id], [name], and optional
  /// [effectiveId], [resolvedName], [isAuto], and [type] metadata.
  const AudioDevice({
    required this.id,
    this.effectiveId = '',
    required this.name,
    String? resolvedName,
    bool isAuto = false,
    this.type,
  })  : _resolvedName = resolvedName,
        _isAuto = isAuto || id == 'AUTO' || id == 'auto' || id == '';

  /// Hardware device name currently routed by the OS when [isAuto] is `true`, or `null` otherwise.
  String? get resolvedName => _resolvedName;

  /// Whether this device represents the automatic system-managed output.
  bool get isAuto => _isAuto;

  /// Automatic system-managed default output audio device template.
  static const AudioDevice auto = AudioDevice(
    id: 'AUTO',
    effectiveId: '',
    name: 'SYSTEM DEFAULT',
    isAuto: true,
  );

  /// User-friendly display name for this device.
  ///
  /// Uses [MiniaudioPlayerGlobalConfig.defaultDeviceDisplayNameResolver] if this
  /// device has [isAuto] set to `true`, otherwise returns [name] directly.
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

  /// Returns `true` if this device and [other] route to the same underlying physical hardware endpoint.
  bool isSameEndpoint(AudioDevice other) {
    if (effectiveId.isNotEmpty && other.effectiveId.isNotEmpty) {
      return effectiveId == other.effectiveId;
    }
    return id == other.id;
  }

  /// Compares this [AudioDevice] with [other] by auto-routing flag or device [id].
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AudioDevice) return false;
    if (isAuto && other.isAuto) return true;
    return id == other.id;
  }

  /// Returns a hash code consistent with [==].
  @override
  int get hashCode => isAuto ? 'AUTO'.hashCode : id.hashCode;

  /// Returns a readable string representation of this [AudioDevice].
  @override
  String toString() =>
      'AudioDevice(id: $id, name: $name, isAuto: $isAuto, effectiveId: $effectiveId${type != null ? ', type: $type' : ''})';
}
