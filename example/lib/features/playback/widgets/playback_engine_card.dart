import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:open_file/open_file.dart';

import '../../../core/models/audio_track.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_card.dart';
import '../../analyzer/controllers/audio_analyzer_controller.dart';
import '../../console/controllers/audio_engine_controller.dart';
import '../../metadata/widgets/metadata_inspector_modal.dart';
import 'live_recording_panel.dart';
import 'playback_header_bar.dart';
import 'playback_transport_bar.dart';
import 'playback_waveform_scrubber.dart';

/// Controller-bound primary playback card hosting track header banner,
/// interactive waveform seek bar, transport controls, varispeed/pitch pills,
/// and the live recording dock.
class PlaybackEngineCard extends StatelessWidget {
  /// Controller owning engine state streams, transport RPCs, and recording.
  final AudioEngineController controller;

  /// Optional analyzer controller providing static waveform/metadata results.
  final AudioAnalyzerController? analyzerController;

  /// Optional test hook overriding platform Web option visibility in
  /// [LiveRecordingPanel].
  @visibleForTesting
  final bool? showWebOptionsOverride;

  /// Creates a [PlaybackEngineCard] bound to [controller], optional
  /// [analyzerController], and optional [showWebOptionsOverride] test override.
  const PlaybackEngineCard({
    super.key,
    required this.controller,
    this.analyzerController,
    @visibleForTesting this.showWebOptionsOverride,
  });

  /// Formats [d] as `MM:SS.t` for completion snackbars.
  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$tenths';
  }

  /// Opens the latest finished capture using the platform opener or shows an
  /// error banner on failure inside [context].
  Future<void> _openLastRecording(BuildContext context) async {
    try {
      final result = await controller.openLastRecording();
      if (context.mounted && result.type != ResultType.done) {
        MapLogger.warn(
          '[PLAYBACK:UI] Could not open recording (${result.type.name}): ${result.message}',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF2D0B14),
            content: Text(
              'Could not open recording (${result.type.name}): ${result.message}',
              style: const TextStyle(color: StudioColors.accentRose),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      MapLogger.error('[PLAYBACK:UI] Failed to open recording: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF2D0B14),
            content: Text(
              'Failed to open recording: $e',
              style: const TextStyle(color: StudioColors.accentRose),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Triggers browser download of the latest finished capture on Web targets.
  Future<void> _downloadLastRecording(BuildContext context) async {
    try {
      final ok = await controller.downloadLastRecording();
      if (context.mounted && !ok) {
        MapLogger.warn('[PLAYBACK:UI] Recording download returned false');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF2D0B14),
            content: Text(
              'Could not download recording.',
              style: TextStyle(color: StudioColors.accentRose),
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      MapLogger.error('[PLAYBACK:UI] Failed to download recording: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF2D0B14),
            content: Text(
              'Failed to download recording: $e',
              style: const TextStyle(color: StudioColors.accentRose),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Loads and plays back the most recent recorded artifact in the queue.
  Future<void> _playLastRecording(BuildContext context) async {
    try {
      await controller.playLastRecording();
    } catch (e) {
      MapLogger.error('[PLAYBACK:UI] Failed to play recording: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF2D0B14),
            content: Text(
              'Failed to play recording: $e',
              style: const TextStyle(color: StudioColors.accentRose),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Removes the most recent recorded artifact and refreshes UI state.
  Future<void> _deleteLastRecording(BuildContext context) async {
    try {
      await controller.deleteLastRecording();
    } catch (e) {
      MapLogger.error('[PLAYBACK:UI] Failed to delete recording: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF2D0B14),
            content: Text(
              'Failed to delete recording: $e',
              style: const TextStyle(color: StudioColors.accentRose),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Executes an asynchronous transport [action] and logs failures through
  /// [MapLogger].
  void _runTransportAction(Future<void> Function() action) {
    action().catchError((Object error) {
      MapLogger.error('[PLAYBACK:UI] Transport action failed: $error');
    });
  }

  /// Seeks the engine to [fraction] (`0.0..1.0`) of track [duration].
  void _seekToFraction(double fraction, Duration? duration) {
    if (duration == null || duration.inMilliseconds <= 0) return;
    final clamped = fraction.clamp(0.0, 1.0);
    final targetMs = (clamped * duration.inMilliseconds).round();
    _runTransportAction(
      () => controller.engine.action.seek(Duration(milliseconds: targetMs)),
    );
  }

  /// Toggles live recording between active capture and completion, displaying a
  /// confirmation or error snackbar inside [context].
  Future<void> _toggleRecording(BuildContext context, bool isRec) async {
    try {
      if (isRec) {
        final res = await controller.stopRecording();
        MapLogger.info(
          '[PLAYBACK:UI] Recording stopped: ${_formatDuration(res.duration)}, ${res.bytesWritten} bytes',
        );
        if (context.mounted) {
          final fileLabel = res.path.split(RegExp(r'[/\\]')).last;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF0E172A),
              content: Text(
                'Recorded ${_formatDuration(res.duration)} (${(res.bytesWritten / 1024).round()} KB)${fileLabel.isNotEmpty ? ' to $fileLabel' : ''}',
                style: const TextStyle(color: StudioColors.accentEmerald),
              ),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      } else {
        await controller.startRecording();
        MapLogger.info('[PLAYBACK:UI] Recording started');
      }
    } catch (e) {
      MapLogger.error('[PLAYBACK:UI] Recording failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF2D0B14),
            content: Text(
              'Recording failed: $e',
              style: const TextStyle(color: StudioColors.accentRose),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Builds the reactive [LiveRecordingPanel] bound to recording state streams.
  Widget _buildRecordingMenu(BuildContext context) {
    final isWebUi = showWebOptionsOverride ?? kIsWeb;

    return ListenableBuilder(
      listenable: controller.recordingListenable,
      builder: (context, _) {
        final isRec = controller.isRecording;
        return StreamBuilder<Duration>(
          stream: controller.engine.stream.recordedDuration,
          initialData: controller.engine.state.recordedDuration,
          builder: (context, snap) {
            final recordedDur = snap.data ?? controller.recordedDuration;
            return LiveRecordingPanel(
              isRecording: isRec,
              recordedDuration: recordedDur,
              isWebUi: isWebUi,
              useWebOpfs: controller.useWebOpfs,
              recordingFormat: controller.recordingFormat,
              recordingSource: controller.recordingSource,
              lastRecordingResult: controller.lastRecordingResult,
              lastRecordingFileName: controller.lastRecordingFileName,
              onToggleRecord: () => _toggleRecording(context, isRec),
              onFormatChanged: controller.setRecordingFormat,
              onSourceChanged: controller.setRecordingSource,
              onUseWebOpfsChanged: controller.setUseWebOpfs,
              onOpenLastRecording: () => _openLastRecording(context),
              onDownloadLastRecording: () => _downloadLastRecording(context),
              onPlayLastRecording: () => _playLastRecording(context),
              onDeleteLastRecording: () => _deleteLastRecording(context),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;

    return StudioCard(
      icon: Icons.graphic_eq,
      title: 'HIGH-RES AUDIO PLAYBACK ENGINE',
      subtitle: 'Dual-Deck Hardware Threads • Sonic DSP Varispeed',
      trailing: ListenableBuilder(
        listenable: controller.trackSelectionListenable,
        builder: (context, _) {
          final track = controller.selectedTrack;
          return StreamBuilder<AudioSource<AudioTrack>?>(
            stream: engine.stream.currentItem,
            initialData: engine.state.currentItem,
            builder: (context, currentSnap) {
              final activeTrack = currentSnap.data?.data ?? track;
              return StreamBuilder<AudioInfo?>(
                stream: engine.stream.audioInfo,
                initialData: engine.state.audioInfo,
                builder: (context, snapshot) {
                  return StudioBadge(
                    label: TrackFormatInfo.deduceFormatBadge(
                      activeTrack,
                      bitrate: snapshot.data?.bitrate ?? 0,
                    ),
                    color: StudioColors.accentAmber,
                  );
                },
              );
            },
          );
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([
              controller.trackSelectionListenable,
              ?analyzerController,
            ]),
            builder: (context, _) {
              final track = controller.selectedTrack;
              return StreamBuilder<AudioSource<AudioTrack>?>(
                stream: engine.stream.currentItem,
                initialData: engine.state.currentItem,
                builder: (context, currentSnap) {
                  final activeTrack = currentSnap.data?.data ?? track;
                  return StreamBuilder<AudioMetadata?>(
                    stream: engine.stream.metadata,
                    initialData: engine.state.metadata,
                    builder: (context, metaSnap) {
                      final dynamicMeta =
                          metaSnap.data ?? engine.state.metadata;
                      final analysis = analyzerController?.getResultForTrack(
                        activeTrack,
                      );

                      final frontCover =
                          dynamicMeta?.frontCover ??
                          analysis?.metadata?.frontCover;

                      final displayTitle =
                          (dynamicMeta?.title != null &&
                              dynamicMeta!.title!.isNotEmpty)
                          ? dynamicMeta.title!
                          : (analysis?.metadata?.title != null &&
                                analysis!.metadata!.title!.isNotEmpty)
                          ? analysis.metadata!.title!
                          : (activeTrack?.title ?? 'No track selected');

                      final displayArtist =
                          (dynamicMeta?.trackArtist != null &&
                              dynamicMeta!.trackArtist!.isNotEmpty)
                          ? dynamicMeta.trackArtist!
                          : (analysis?.metadata?.trackArtist != null &&
                                analysis!.metadata!.trackArtist!.isNotEmpty)
                          ? analysis.metadata!.trackArtist!
                          : (activeTrack?.artist ??
                                'Select a track from the queue');

                      return StreamBuilder<Buffer>(
                        stream: engine.stream.buffer,
                        initialData: engine.state.buffer,
                        builder: (context, bufSnap) {
                          final buffer = bufSnap.data ?? engine.state.buffer;
                          return PlaybackHeaderBar(
                            activeTrack: activeTrack,
                            displayTitle: displayTitle,
                            displayArtist: displayArtist,
                            frontCover: frontCover,
                            buffer: buffer,
                            onInspectMetadata: activeTrack == null
                                ? null
                                : () {
                                    showDialog<void>(
                                      context: context,
                                      builder: (_) => MetadataInspectorModal(
                                        track: activeTrack,
                                        staticMetadata: analysis?.metadata,
                                        dynamicMetadata: engine.state.metadata,
                                        staticAudioInfo: analysis?.audioInfo,
                                        dynamicAudioInfo:
                                            engine.state.audioInfo,
                                      ),
                                    );
                                  },
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
          const SizedBox(height: 10),
          StreamBuilder<Duration?>(
            stream: engine.stream.duration,
            initialData: engine.state.duration,
            builder: (context, durSnap) {
              final dur = durSnap.data ?? engine.state.duration;
              return StreamBuilder<Duration>(
                stream: engine.stream.position,
                initialData: engine.state.position,
                builder: (context, posSnap) {
                  final pos = posSnap.data ?? Duration.zero;
                  return StreamBuilder<Buffer>(
                    stream: engine.stream.buffer,
                    initialData: engine.state.buffer,
                    builder: (context, bufSnap) {
                      final buf = bufSnap.data ?? engine.state.buffer;
                      return ListenableBuilder(
                        listenable: controller.waveformListenable,
                        builder: (context, _) {
                          return PlaybackWaveformScrubber(
                            waveformPoints: controller.waveformPoints,
                            position: pos,
                            duration: dur,
                            buffer: buf,
                            onSeekFraction: (frac) =>
                                _seekToFraction(frac, dur),
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),
          StreamBuilder<PlaybackState>(
            stream: engine.stream.playbackState,
            initialData: engine.state.playbackState,
            builder: (context, stateSnap) {
              final state = stateSnap.data ?? PlaybackState.stopped;
              final isPlaying = state == PlaybackState.playing;
              return StreamBuilder<bool>(
                stream: engine.stream.isShuffled,
                initialData: engine.state.isShuffled,
                builder: (context, shuffleSnap) {
                  final isShuffled = shuffleSnap.data ?? false;
                  return StreamBuilder<LoopMode>(
                    stream: engine.stream.loopMode,
                    initialData: engine.state.loopMode,
                    builder: (context, loopSnap) {
                      final loopMode = loopSnap.data ?? LoopMode.off;
                      return ListenableBuilder(
                        listenable: controller.transportControlsListenable,
                        builder: (context, _) {
                          return PlaybackTransportBar(
                            playbackState: state,
                            isShuffled: isShuffled,
                            loopMode: loopMode,
                            volume: controller.volume,
                            rate: controller.rate,
                            pitch: controller.pitch,
                            onPrevious: controller.previousTrack,
                            onPlayPause: () {
                              _runTransportAction(
                                isPlaying
                                    ? engine.action.pause
                                    : engine.action.play,
                              );
                            },
                            onNext: controller.nextTrack,
                            onStop: () =>
                                _runTransportAction(engine.action.stop),
                            onToggleShuffle: controller.toggleShuffle,
                            onToggleLoop: controller.toggleLoop,
                            onVolumeChanged: controller.setVolume,
                            onRateChanged: controller.setRate,
                            onPitchChanged: controller.setPitch,
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
          const SizedBox(height: 10),
          _buildRecordingMenu(context),
        ],
      ),
    );
  }
}
