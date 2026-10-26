import 'package:flutter/material.dart';
import 'controllers/audio_analyzer_controller.dart';
import 'controllers/audio_engine_controller.dart';
import 'models/audio_track.dart';
import 'theme/studio_colors.dart';
import 'theme/studio_theme.dart';
import 'views/ingest_matrix_view.dart';
import 'views/studio_console_view.dart';
import 'widgets/common/studio_badge.dart';
import 'widgets/header/console_header.dart';

class MiniaudioPlayerExampleApp extends StatelessWidget {
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

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final AudioEngineController _playerController = AudioEngineController();
  final AudioAnalyzerController _analyzerController = AudioAnalyzerController();

  ViewMode _currentMode = ViewMode.studioConsole;

  AudioTrack? _lastAnalyzedTrack;

  @override
  void initState() {
    super.initState();
    _analyzerController.addListener(_onAnalyzerUpdate);
    _playerController.addListener(_onPlayerUpdate);
    _initApp();
  }

  void _onAnalyzerUpdate() {
    final curTrack = _playerController.selectedTrack;
    if (curTrack != null) {
      final res = _analyzerController.getResultForTrack(curTrack);
      final pts = res?.waveform?.points;
      if (pts != null && pts.isNotEmpty) {
        _playerController.updateWaveformPoints(pts, trackId: curTrack.id);
      }
    }
  }

  void _onPlayerUpdate() {
    final curTrack = _playerController.selectedTrack;
    if (curTrack != null && curTrack.id != _lastAnalyzedTrack?.id) {
      _lastAnalyzedTrack = curTrack;
      _analyzerController.setCurrentTrack(curTrack, _playerController.engine);
      if (curTrack.canAnalyze &&
          !_analyzerController.hasResultForTrack(curTrack)) {
        _analyzerController.analyze(curTrack);
      }
    }
  }

  Future<void> _initApp() async {
    await _playerController.init();
    if (mounted) {
      final curTrack = _playerController.selectedTrack;
      if (curTrack != null) {
        _lastAnalyzedTrack = curTrack;
        _analyzerController.setCurrentTrack(curTrack, _playerController.engine);
        if (curTrack.canAnalyze &&
            !_analyzerController.hasResultForTrack(curTrack)) {
          _analyzerController.analyze(curTrack);
        }
      }
      setState(() {});
    }
  }

  void _onModeChanged(ViewMode mode) {
    setState(() {
      _currentMode = mode;
    });
  }

  @override
  void dispose() {
    _analyzerController.removeListener(_onAnalyzerUpdate);
    _playerController.removeListener(_onPlayerUpdate);
    _playerController.dispose();
    _analyzerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_playerController.isReady) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        backgroundColor: const Color(0xFF070B14),
        elevation: 0,
        titleSpacing: 16.0,
        title: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 700;
            return Row(
              children: [
                // Left block: [icono + titulo + minidescripcion debajo]
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Image.asset(
                              'assets/icon.png',
                              width: 24,
                              height: 24,
                              errorBuilder: (context, error, stackTrace) =>
                                  const Icon(
                                Icons.graphic_eq,
                                color: StudioColors.accentCyan,
                                size: 24,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: ShaderMask(
                                shaderCallback: (bounds) =>
                                    StudioColors.titleGradient.createShader(bounds),
                                child: const Text(
                                  'miniaudio_player',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Ultra-Low-Resource Native Audio Engine & DSP Architecture for Flutter & Dart',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w500,
                          color: StudioColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Right block: [badges] on wide screens
                if (!isCompact) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      alignment: WrapAlignment.end,
                      children: const [
                        StudioBadge(
                          label: 'O(1) Real-Time & 0 Heap Alloc',
                          emoji: '⚡',
                          color: StudioColors.accentCyan,
                        ),
                        StudioBadge(
                          label: '100% Pure Dart FFI',
                          emoji: '🔀',
                          color: StudioColors.accentViolet,
                        ),
                        StudioBadge(
                          label: 'Hardware Limiter',
                          emoji: '🛡️',
                          color: StudioColors.accentAmber,
                        ),
                        StudioBadge(
                          label: 'Studio Reverb',
                          emoji: '🏛️',
                          color: StudioColors.accentEmerald,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
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
              ViewMode.ingestMatrix => const IngestMatrixView(),
            },
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
