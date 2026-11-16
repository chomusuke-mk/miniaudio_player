/// Ultra-low-resource cross-platform audio player and DSP engine using miniaudio and Sonic DSP.
///
/// Features dual-deck streaming, gapless playback, crossfading, a 10-band equalizer,
/// algorithmic reverb, 3D spatial audio with Doppler kinematics, microphone auto-ducking,
/// multi-destination output matrix (speakers, DJ cue pre-listening, live recording),
/// and real-time spectrum visualizer.
library;

export 'package:flutter/services.dart' show RootIsolateToken;

export 'src/api/audio_analysis_result.dart';
export 'src/api/audio_device.dart';
export 'src/api/audio_info.dart';
export 'src/api/audio_metadata.dart';
export 'src/api/buffer.dart';
export 'src/api/crossfade_config.dart';
export 'src/api/dsp_config.dart';
export 'src/api/logger.dart';
export 'src/api/loop_mode.dart';
export 'src/api/miniaudio_player.dart';
export 'src/api/need_more_tracks_event.dart';
export 'src/api/player_exception.dart';
export 'src/api/player_models.dart';
export 'src/api/recording.dart';
export 'src/api/silence_skip_config.dart';
export 'src/api/spatial.dart';
export 'src/api/visualizer_data.dart';
export 'src/crossfeed.dart';
export 'src/equalizer.dart';
export 'src/infinite_mix.dart';
export 'src/loader/custom_byte_provider.dart';
export 'src/reverb.dart';
