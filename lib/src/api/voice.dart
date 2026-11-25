part of 'miniaudio_player.dart';

/// Handle to a live, running polyphonic sound effect voice rendered in the native voice pool.
///
/// Returned by [PlayerAction.playEffect] to modulate continuous or looping sound
/// effects in real time (for example, moving vehicles, engine loops, or ambient 3D emitters)
/// without restarting playback.
class Voice {
  /// Unique identifier of this active polyphonic voice (`> 0` when active).
  final int id;

  /// Owning [PlayerAction] dispatcher used to modulate or stop this voice.
  final PlayerAction<dynamic> _action;

  /// Creates a [Voice] handle bound to [id] and the owning dispatcher [_action].
  const Voice(this.id, this._action);

  /// Modulates the linear [volume] of this active voice in real time (`>= 0.0`).
  Future<void> setVolume(double volume) => _action._setVoiceVolume(id, volume);

  /// Modulates the [pitch] multiplier of this active voice in real time (`> 0.0`).
  Future<void> setPitch(double pitch) => _action._setVoicePitch(id, pitch);

  /// Modulates the stereo [balance] of this active voice in real time (`-1.0` to `1.0`).
  Future<void> setBalance(double balance) =>
      _action._setVoiceBalance(id, balance);

  /// Updates the 3D spatial [emitter] position and velocity of this active voice in real time.
  Future<void> setEmitter(SpatialEmitter emitter) =>
      _action._setVoiceEmitter(id, emitter);

  /// Stops this active voice with a linear [fadeOut] ramp.
  Future<void> stop({Duration fadeOut = const Duration(milliseconds: 5)}) =>
      _action._stopVoice(id, fadeOut: fadeOut);

  /// Compares this [Voice] handle with [other] by voice [id].
  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Voice && id == other.id);

  /// Returns a hash code derived from [id].
  @override
  int get hashCode => id.hashCode;

  /// Returns a concise string representation of this [Voice] handle.
  @override
  String toString() => 'Voice($id)';
}
