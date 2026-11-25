import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../core/models/audio_track.dart';
import '../core/theme/studio_theme.dart';
import '../features/analyzer/controllers/audio_analyzer_controller.dart';
import '../features/analyzer/views/audio_analyzer_view.dart';
import '../features/console/controllers/audio_engine_controller.dart';
import '../features/console/views/studio_console_view.dart';
import '../features/ingest/views/ingest_matrix_view.dart';
import 'console_header.dart';
import 'studio_app_bar.dart';

/// Root Material application shell configuring [StudioTheme.darkTheme] and
/// hosting [PlayerScreen].
class MiniaudioPlayerExampleApp extends StatelessWidget {
  /// Creates the [MiniaudioPlayerExampleApp] widget.
  const MiniaudioPlayerExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'miniaudio_player Demo',
      debugShowCheckedModeBanner: false,
      theme: StudioTheme.darkTheme,
      home: const PlayerScreen(),
    );
  }
}

/// Top-level scaffold coordinating engine/analyzer controller lifecycles,
/// navigation across studio workspaces, and waveform synchronization.
class PlayerScreen extends StatefulWidget {
  /// Creates the primary [PlayerScreen] route.
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

/// Manages active controllers, navigation tab state, and analyzer sync hooks
/// inside [PlayerScreen].
class _PlayerScreenState extends State<PlayerScreen> {
  /// Primary playback, DSP, routing, and recording controller.
  final AudioEngineController _playerController = AudioEngineController();

  /// On-demand BS.1770-4 / EBU R128 acoustic analyzer controller.
  final AudioAnalyzerController _analyzerController = AudioAnalyzerController();

  /// Currently selected console tab displayed below [ConsoleHeader].
  ViewMode _currentMode = ViewMode.studioConsole;

  /// Tracks the latest [AudioEngineController.isReady] flag to avoid redundant
  /// screen-level rebuilds after initial boot.
  bool _lastReady = false;

  @override
  void initState() {
    super.initState();
    MapLogger.info('[APP:INIT] Starting PlayerScreen controllers');
    _analyzerController.addListener(_onAnalyzerUpdate);
    _playerController.trackSelectionListenable.addListener(_onPlayerUpdate);
    _initApp();
  }

  /// Synchronizes cached or analyzed waveform bars for [track] onto
  /// [_playerController].
  void _syncWaveformForTrack(AudioTrack track) {
    _analyzerController.selectTrack(track);
    final res = _analyzerController.getResultForTrack(track);
    final pts = res?.waveform?.points;
    if (pts != null && pts.isNotEmpty) {
      _playerController.updateWaveformPoints(pts, trackId: track.id);
    } else if (_playerController.hasCachedWaveform(track.id)) {
      final cached = _playerController.getCachedWaveform(track.id)!;
      _playerController.updateWaveformPoints(cached, trackId: track.id);
    } else {
      _playerController.resetWaveformToSinusoidal();
    }
  }

  /// Re-syncs the waveform display when analysis finishes for the active track.
  void _onAnalyzerUpdate() {
    final curTrack = _playerController.selectedTrack;
    if (curTrack != null) {
      _syncWaveformForTrack(curTrack);
    }
  }

  /// Responds to engine readiness and track selection updates by syncing the
  /// waveform and triggering background analysis when uncached.
  void _onPlayerUpdate() {
    if (!_lastReady && _playerController.isReady) {
      _lastReady = true;
      if (mounted) setState(() {});
    }
    final curTrack = _playerController.selectedTrack;
    if (curTrack != null) {
      _syncWaveformForTrack(curTrack);
      if (curTrack.canAnalyze &&
          !_analyzerController.hasResultForTrack(curTrack) &&
          !_analyzerController.hasErrorForTrack(curTrack) &&
          !_analyzerController.isAnalyzingTrack(curTrack)) {
        _analyzerController.analyze(curTrack, engine: _playerController.engine);
      }
    }
  }

  /// Initializes [_playerController] and triggers initial acoustic analysis for
  /// the first selected queue track.
  Future<void> _initApp() async {
    await _playerController.init();
    MapLogger.info('[APP:READY] Engine controller initialized');
    if (mounted) {
      final curTrack = _playerController.selectedTrack;
      if (curTrack != null) {
        _syncWaveformForTrack(curTrack);
        if (curTrack.canAnalyze &&
            !_analyzerController.hasResultForTrack(curTrack)) {
          _analyzerController.analyze(
            curTrack,
            engine: _playerController.engine,
          );
        }
      }
      setState(() {});
    }
  }

  /// Switches the active workspace tab to [mode].
  void _onModeChanged(ViewMode mode) {
    MapLogger.info('[APP:NAV] Switched console tab -> ${mode.name}');
    setState(() {
      _currentMode = mode;
    });
  }

  @override
  void dispose() {
    MapLogger.debug('[APP:DISPOSE] Releasing PlayerScreen controllers');
    _analyzerController.removeListener(_onAnalyzerUpdate);
    _playerController.trackSelectionListenable.removeListener(_onPlayerUpdate);
    _playerController.dispose();
    _analyzerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_playerController.isReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: const StudioAppBar(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConsoleHeader(
              currentMode: _currentMode,
              onModeChanged: _onModeChanged,
            ),
            const SizedBox(height: 16),
            switch (_currentMode) {
              ViewMode.studioConsole => StudioConsoleView(
                playerController: _playerController,
                analyzerController: _analyzerController,
              ),
              ViewMode.audioAnalyzer => AudioAnalyzerView(
                playerController: _playerController,
                analyzerController: _analyzerController,
              ),
              ViewMode.ingestMatrix => const IngestMatrixView(),
            },
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
