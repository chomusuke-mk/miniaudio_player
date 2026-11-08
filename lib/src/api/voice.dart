part of 'miniaudio_player.dart';

/// Handle to a live, running polyphonic sound effect voice rendered in the native voice pool.
///
/// Returned by `player.action.playEffect(...)` to modulate continuous or looping sound
/// effects in real time (e.g. moving vehicles, engine loops, ambient 3D emitters) without
/// restarting playback.
class Voice {
  /// The unique identifier of this active polyphonic voice (`> 0` when active).
  final int id;

  final PlayerAction<dynamic> _action;

  /// Creates a [Voice] handle bound to [id] and [_action].
  const Voice(this.id, this._action);

  /// Modulates the linear volume of this active voice in real time (`>= 0.0`).
  Future<void> setVolume(double volume) => _action._setVoiceVolume(id, volume);

  /// Modulates the pitch multiplier of this active voice in real time (`> 0.0`).
  Future<void> setPitch(double pitch) => _action._setVoicePitch(id, pitch);

  /// Modulates the stereo balance of this active voice in real time (`-1.0` to `1.0`).
  Future<void> setBalance(double balance) =>
      _action._setVoiceBalance(id, balance);

  /// Updates the 3D spatial position and velocity of this active voice in real time.
  Future<void> setEmitter(SpatialEmitter emitter) =>
      _action._setVoiceEmitter(id, emitter);

  /// Stops this active voice with a linear [fadeOut] ramp.
  Future<void> stop({Duration fadeOut = const Duration(milliseconds: 5)}) =>
      _action._stopVoice(id, fadeOut: fadeOut);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Voice && id == other.id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Voice($id)';
}
