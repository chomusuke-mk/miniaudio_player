import 'api/logger.dart';

/// Immutable studio-grade algorithmic reverberation configuration for `miniaudio_player`.
///
/// Models an acoustic space utilizing a physical Freeverb network with `8`
/// parallel low-pass feedback comb filters and `4` cascaded allpass filters
/// per channel.
class Reverb {
  /// Whether the reverb effect is actively processing audio.
  final bool enabled;

  /// Normalized room size factor (`0.0` to `1.0`) determining reflection decay time.
  final double roomSize;

  /// High-frequency absorption and damping factor (`0.0` to `1.0`).
  ///
  /// Higher values result in darker, warmer room reflections as high
  /// frequencies decay faster.
  final double damping;

  /// Stereo width and spread of the reverberation reflections (`0.0` to `1.0`).
  ///
  /// A value of `0.0` produces mono reverberation, while `1.0` produces maximum
  /// stereophonic space.
  final double width;

  /// Wet signal mix level (`0.0` to `2.0`, defaults to `0.33`).
  final double wet;

  /// Dry (unprocessed direct sound) mix level (`0.0` to `2.0`, defaults to `1.0`).
  final double dry;

  /// Creates an immutable [Reverb] configuration.
  ///
  /// Configures whether processing is [enabled], along with [roomSize],
  /// [damping], [width], [wet], and [dry] mix levels.
  const Reverb({
    this.enabled = false,
    this.roomSize = 0.5,
    this.damping = 0.5,
    this.width = 1.0,
    this.wet = 0.33,
    this.dry = 1.0,
  })  : assert(roomSize >= 0.0 && roomSize <= 1.0,
            'roomSize must be between 0.0 and 1.0'),
        assert(damping >= 0.0 && damping <= 1.0,
            'damping must be between 0.0 and 1.0'),
        assert(
            width >= 0.0 && width <= 1.0, 'width must be between 0.0 and 1.0'),
        assert(wet >= 0.0 && wet <= 2.0, 'wet must be between 0.0 and 2.0'),
        assert(dry >= 0.0 && dry <= 2.0, 'dry must be between 0.0 and 2.0');

  /// Completely disabled and bypassed reverb effect.
  static const Reverb off = Reverb(
    enabled: false,
    roomSize: 0.0,
    damping: 0.0,
    width: 1.0,
    wet: 0.0,
    dry: 1.0,
  );

  /// Tight, intimate small-room preset with fast decay.
  ///
  /// Ideal for dry vocal enhancement and subtle acoustic dimension without
  /// washing out transients.
  static const Reverb smallRoom = Reverb(
    enabled: true,
    roomSize: 0.25,
    damping: 0.65,
    width: 0.8,
    wet: 0.20,
    dry: 1.0,
  );

  /// Balanced natural medium-room studio ambience preset.
  ///
  /// Well suited for drums, acoustic guitars, and pop or rock tracks.
  static const Reverb studio = Reverb(
    enabled: true,
    roomSize: 0.50,
    damping: 0.50,
    width: 1.0,
    wet: 0.30,
    dry: 1.0,
  );

  /// Expansive large concert hall preset with lush reflection density.
  ///
  /// Designed for orchestral recordings, symphonies, and live venue emulation.
  static const Reverb concertHall = Reverb(
    enabled: true,
    roomSize: 0.80,
    damping: 0.35,
    width: 1.0,
    wet: 0.40,
    dry: 0.95,
  );

  /// Massive cathedral preset with lengthy decay and shimmering upper harmonics.
  static const Reverb cathedral = Reverb(
    enabled: true,
    roomSize: 0.94,
    damping: 0.20,
    width: 1.0,
    wet: 0.50,
    dry: 0.85,
  );

  /// Dense, bright metallic plate preset modeled after vintage EMT studio plates.
  static const Reverb plate = Reverb(
    enabled: true,
    roomSize: 0.65,
    damping: 0.10,
    width: 1.0,
    wet: 0.35,
    dry: 0.95,
  );

  /// Expansive, dreamy ambient preset with extended tail and high wet ratio.
  static const Reverb ambient = Reverb(
    enabled: true,
    roomSize: 0.92,
    damping: 0.70,
    width: 1.0,
    wet: 0.60,
    dry: 0.70,
  );

  /// Convenient map of all standard reverb presets keyed by display name.
  static const Map<String, Reverb> presets = {
    'Off': off,
    'Small Room': smallRoom,
    'Studio': studio,
    'Concert Hall': concertHall,
    'Cathedral': cathedral,
    'Plate': plate,
    'Ambient': ambient,
  };

  /// Returns a copy of this [Reverb] with modified properties.
  ///
  /// Overrides [enabled], [roomSize], [damping], [width], [wet], and [dry]
  /// when non-`null`.
  Reverb copyWith({
    bool? enabled,
    double? roomSize,
    double? damping,
    double? width,
    double? wet,
    double? dry,
  }) {
    return Reverb(
      enabled: enabled ?? this.enabled,
      roomSize: roomSize ?? this.roomSize,
      damping: damping ?? this.damping,
      width: width ?? this.width,
      wet: wet ?? this.wet,
      dry: dry ?? this.dry,
    );
  }

  /// Returns a deterministic [Reverb] configuration with all acoustic parameters
  /// clamped to their valid DSP domain ranges.
  ///
  /// Clamps [roomSize], [damping], and [width] to `[0.0, 1.0]` and [wet] and
  /// [dry] to `[0.0, 2.0]`.
  Reverb validated() {
    final clampedRoomSize = roomSize.clamp(0.0, 1.0);
    final clampedDamping = damping.clamp(0.0, 1.0);
    final clampedWidth = width.clamp(0.0, 1.0);
    final clampedWet = wet.clamp(0.0, 2.0);
    final clampedDry = dry.clamp(0.0, 2.0);
    if (clampedRoomSize != roomSize ||
        clampedDamping != damping ||
        clampedWidth != width ||
        clampedWet != wet ||
        clampedDry != dry) {
      MapLogger.debug(
        'Reverb.validated() clamped parameters: '
        'roomSize=$roomSize->$clampedRoomSize, '
        'damping=$damping->$clampedDamping, '
        'width=$width->$clampedWidth, '
        'wet=$wet->$clampedWet, '
        'dry=$dry->$clampedDry',
      );
    }
    return Reverb(
      enabled: enabled,
      roomSize: clampedRoomSize,
      damping: clampedDamping,
      width: clampedWidth,
      wet: clampedWet,
      dry: clampedDry,
    );
  }

  /// Returns `true` if [other] is a [Reverb] with matching enabled state and
  /// parameters within `1e-4`.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Reverb &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          (roomSize - other.roomSize).abs() < 1e-4 &&
          (damping - other.damping).abs() < 1e-4 &&
          (width - other.width).abs() < 1e-4 &&
          (wet - other.wet).abs() < 1e-4 &&
          (dry - other.dry).abs() < 1e-4;

  /// Returns a hash code derived from [enabled], [roomSize], [damping],
  /// [width], [wet], and [dry].
  @override
  int get hashCode => Object.hash(
        enabled,
        roomSize,
        damping,
        width,
        wet,
        dry,
      );

  /// Returns a human-readable string representation of this [Reverb].
  @override
  String toString() {
    return 'Reverb(enabled: $enabled, roomSize: $roomSize, damping: $damping, '
        'width: $width, wet: $wet, dry: $dry)';
  }
}
