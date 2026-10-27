import 'miniaudio_player.dart';

/// Represents an audio output device.
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
      final resolver =
          MiniaudioPlayer.config().defaultDeviceDisplayNameResolver;
      return resolver(_resolvedName ?? '');
    }
    return name;
  }

  /// Checks whether this device and [other] route to the same physical hardware endpoint.
  bool isSameEndpoint(AudioDevice other) {
    final myEff = effectiveId.isNotEmpty ? effectiveId : id;
    final otherEff = other.effectiveId.isNotEmpty ? other.effectiveId : other.id;
    if (myEff.isNotEmpty && otherEff.isNotEmpty) {
      return myEff == otherEff;
    }
    return this == other;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AudioDevice &&
          runtimeType == other.runtimeType &&
          ((isAuto && other.isAuto) || id == other.id));

  @override
  int get hashCode => isAuto ? 'auto'.hashCode : id.hashCode;

  @override
  String toString() =>
      'AudioDevice(id: $id, effectiveId: $effectiveId, name: $name, auto: $_isAuto${_resolvedName != null ? ", resolved: $_resolvedName" : ""}${type != null ? ", type: $type" : ""})';
}
