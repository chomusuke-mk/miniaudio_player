import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_card.dart';
import '../../console/controllers/audio_engine_controller.dart';
import 'spectrum_visualizer_panel.dart';

/// Card hosting the real-time 10-band spectrum analyzer and stereo L/R VU meter
/// fed by [AudioEngineController].
class SpectrumVisualizerCard extends StatelessWidget {
  /// Console controller exposing visualizer enable/source actions and streams.
  final AudioEngineController controller;

  /// Creates a [SpectrumVisualizerCard] bound to [controller].
  const SpectrumVisualizerCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: controller.visualizerControlsListenable,
        builder: (context, _) {
          final isEnabled = controller.visualizerEnabled;

          return StudioCard(
            icon: Icons.ssid_chart,
            title: 'Real-Time Reactive Visualizer',
            subtitle:
                '10-Band BPF Filter Bank • Instant RMS & True-Peak Detection',
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.cardBorder),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<AudioOutputSource>(
                      value: controller.visualizerSource,
                      isDense: true,
                      icon: const Icon(Icons.arrow_drop_down, size: 16),
                      dropdownColor: const Color(0xFF0E172A),
                      items: const [
                        DropdownMenuItem(
                          value: AudioOutputSource.all,
                          child: Text(
                            'All Mix',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.musicMix,
                          child: Text(
                            'Music Only',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.activeTrack,
                          child: Text(
                            'Active Deck',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.standbyTrack,
                          child: Text(
                            'Cue Deck',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.voiceOnly,
                          child: Text(
                            'Voice Only',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      onChanged: isEnabled
                          ? (src) {
                              if (src != null) {
                                controller.setVisualizerSource(src);
                              }
                            }
                          : null,
                    ),
                  ),
                ),
                const StudioBadge(
                  label: '0% Idle CPU',
                  color: StudioColors.accentEmerald,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isEnabled ? 'ON' : 'OFF',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isEnabled
                            ? StudioColors.accentCyan
                            : StudioColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Switch(
                      value: isEnabled,
                      activeThumbColor: StudioColors.accentCyan,
                      onChanged: controller.setVisualizerEnabled,
                    ),
                  ],
                ),
              ],
            ),
            child: AnimatedOpacity(
              opacity: isEnabled ? 1.0 : 0.38,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !isEnabled,
                child: _ReactiveVisualizerCanvases(
                  engine: controller.engine,
                  isActive: isEnabled,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Stateful adapter bridging [MiniaudioPlayer.stream.visualizer] updates into
/// a [ValueNotifier] consumed by [SpectrumVisualizerPanel].
class _ReactiveVisualizerCanvases extends StatefulWidget {
  /// Native player engine whose `visualizer` stream feeds canvas repaints.
  final MiniaudioPlayer<dynamic> engine;

  /// Whether visualizer DSP rendering is enabled.
  final bool isActive;

  /// Creates a [_ReactiveVisualizerCanvases] widget subscribed to [engine]
  /// with active flag [isActive].
  const _ReactiveVisualizerCanvases({
    required this.engine,
    required this.isActive,
  });

  @override
  State<_ReactiveVisualizerCanvases> createState() =>
      _ReactiveVisualizerCanvasesState();
}

/// Subscribes to `visualizer` stream ticks for [_ReactiveVisualizerCanvases].
class _ReactiveVisualizerCanvasesState
    extends State<_ReactiveVisualizerCanvases> {
  /// Cached notifier holding the latest decoded [VisualizerData] frame.
  late final ValueNotifier<VisualizerData> _visNotifier = ValueNotifier(
    widget.engine.state.visualizer,
  );

  /// Active subscription listening to `engine.stream.visualizer`.
  StreamSubscription<VisualizerData>? _visSub;

  @override
  void initState() {
    super.initState();
    _visSub = widget.engine.stream.visualizer.listen((data) {
      _visNotifier.value = data;
    });
  }

  @override
  void didUpdateWidget(covariant _ReactiveVisualizerCanvases oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      _visSub?.cancel();
      _visNotifier.value = widget.engine.state.visualizer;
      _visSub = widget.engine.stream.visualizer.listen((data) {
        _visNotifier.value = data;
      });
    }
  }

  @override
  void dispose() {
    _visSub?.cancel();
    _visNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SpectrumVisualizerPanel(
      dataListenable: _visNotifier,
      isActive: widget.isActive,
    );
  }
}
