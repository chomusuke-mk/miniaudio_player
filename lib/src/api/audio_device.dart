/// Represents an audio output device.
class AudioDevice {
  /// Unique device identifier (hex-encoded string for hardware devices, or empty for automatic default).
  final String id;

  /// Human-readable device name (e.g. "Auriculares", "Audio Interno").
  final String name;

  /// Whether this device is currently the operating system's default playback device.
  final bool isDefault;

  /// Whether this device represents the automatic system-managed output.
  final bool isAuto;

  const AudioDevice({
    required this.id,
    required this.name,
    this.isDefault = false,
    this.isAuto = false,
  });

  /// Automatic / system-managed default output audio device template.
  static const AudioDevice auto = AudioDevice(
    id: '',
    name: 'Default',
    isDefault: true,
    isAuto: true,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioDevice &&
          runtimeType == other.runtimeType &&
          isAuto == other.isAuto &&
          (isAuto ? true : id == other.id);

  @override
  int get hashCode => isAuto ? 0 : id.hashCode;

  @override
  String toString() =>
      'AudioDevice(name: $name, id: ${id.isEmpty ? "auto" : (id.length > 8 ? "${id.substring(0, 8)}..." : id)}, default: $isDefault, auto: $isAuto)';
}
