import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MiniaudioPlayer.config(
    defaultBufferSize: 0,
    logLevel: MiniaudioLogLevel.verbose,
    defaultAudioDevice: AudioDevice.auto,
  );
  runApp(const MiniaudioPlayerExampleApp());
}

class AudioTrack {
  final String id;
  final String title;
  final String? assetPath;
  final String? filePath;
  final bool isGenerated;

  const AudioTrack({
    required this.id,
    required this.title,
    this.assetPath,
    this.filePath,
    this.isGenerated = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioTrack && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class MiniaudioPlayerExampleApp extends StatelessWidget {
  const MiniaudioPlayerExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Miniaudio Player Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
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
  final MiniaudioPlayer _player = MiniaudioPlayer();
  List<AudioTrack> _availableTracks = [];
  AudioTrack? _selectedTrack;
  String? _samplePath;
  bool _isReady = false;
  bool _isLoadingTrack = false;

  Equalizer _currentEqualizer = Equalizer.flat;
  String? _selectedPreset = 'flat';

  static String? _detectPreset(Equalizer eq) {
    if (eq == Equalizer.flat) return 'flat';
    if (eq == Equalizer.rock) return 'rock';
    if (eq == Equalizer.pop) return 'pop';
    if (eq == Equalizer.jazz) return 'jazz';
    if (eq == Equalizer.classical) return 'classical';
    if (eq == Equalizer.bassBoost) return 'bassBoost';
    return null;
  }
  double _volume = 1.0;
  double _rate = 1.0;
  double _pitch = 1.0;
  double? _dragPositionMs;
  List<AudioDevice> _audioDevices = [AudioDevice.auto];
  StreamSubscription<AudioDevice>? _deviceSub;
  StreamSubscription<List<AudioDevice>>? _deviceListSub;
  StreamSubscription<Equalizer>? _equalizerSub;
  StreamSubscription<SilenceSkipConfig>? _silenceConfigSub;
  StreamSubscription<double>? _volumeSub;
  StreamSubscription<double>? _rateSub;
  StreamSubscription<double>? _pitchSub;

  AudioAnalysisResult? _analysisResult;
  bool _isAnalyzing = false;
  SilenceSkipMode _silenceMode = SilenceSkipMode.continuous;
  double _silenceThresholdDb = -45.0;
  int _minSilenceDurationMs = 300;
  int _silencePaddingMs = 50;
  bool _replayGainPreventClipping = true;

  Future<void> _runAnalysis() async {
    final path = _samplePath;
    if (path == null || path.isEmpty) return;
    if (mounted) {
      setState(() {
        _isAnalyzing = true;
      });
    }
    try {
      final result = await MiniaudioPlayer.analyzeAudio(
        path,
        waveform: true,
        replayGain: true,
        waveformPoints: 72,
      );
      if (mounted) {
        setState(() {
          _analysisResult = result;
        });
      }
    } catch (e) {
      debugPrint('Error analyzing audio: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _prepareAudioTracks();
    _refreshAudioDevices();
    _deviceSub = _player.stream.audioDevice.listen((_) {
      _refreshAudioDevices();
    });
    _deviceListSub = MiniaudioPlayer.getAudioDevicesStream().listen((devs) {
      if (mounted) {
        setState(() {
          _audioDevices = devs;
        });
      }
    });
    _equalizerSub = _player.stream.equalizer.listen((eq) {
      if (mounted) {
        setState(() {
          _currentEqualizer = eq;
          _selectedPreset = _detectPreset(eq);
        });
      }
    });
    _silenceConfigSub = _player.stream.silenceConfig.listen((cfg) {
      if (mounted) {
        setState(() {
          if (cfg.mode != SilenceSkipMode.disabled) {
            _silenceMode = cfg.mode;
          }
          _silenceThresholdDb = cfg.thresholdDb;
          _minSilenceDurationMs = cfg.minSilenceDuration.inMilliseconds;
          _silencePaddingMs = cfg.padding.inMilliseconds;
        });
      }
    });
    _volumeSub = _player.stream.volume.listen((v) {
      if (mounted && (_volume - v).abs() > 0.001) {
        setState(() => _volume = v);
      }
    });
    _rateSub = _player.stream.rate.listen((r) {
      if (mounted && (_rate - r).abs() > 0.001) {
        setState(() => _rate = r);
      }
    });
    _pitchSub = _player.stream.pitch.listen((p) {
      if (mounted && (_pitch - p).abs() > 0.001) {
        setState(() => _pitch = p);
      }
    });
  }

  Future<void> _refreshAudioDevices() async {
    try {
      final devs = await MiniaudioPlayer.getAudioDevices();
      if (mounted) {
        setState(() {
          _audioDevices = devs;
        });
      }
    } catch (_) {}
  }

  bool _isAudioFile(String path) {
    final lower = path.toLowerCase();
    return miniAudioPlayerSupportedExtensions.any(
      (ext) => lower.endsWith('.$ext'),
    );
  }

  Future<void> _prepareAudioTracks() async {
    final List<AudioTrack> tracks = [];
    final Set<String> seenFilenames = {};

    void addTrack({
      required String id,
      required String title,
      String? assetPath,
      String? filePath,
      bool isGenerated = false,
    }) {
      final filename = (assetPath ?? filePath ?? id)
          .split(RegExp(r'[/\\]'))
          .last;
      if (seenFilenames.contains(filename)) return;
      seenFilenames.add(filename);
      tracks.add(
        AudioTrack(
          id: id,
          title: title,
          assetPath: assetPath,
          filePath: filePath,
          isGenerated: isGenerated,
        ),
      );
    }

    // 1. Scan Flutter AssetManifest strictly under assets/music/
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest.listAssets();
      for (final asset in assets) {
        if (asset.startsWith('assets/music/') && _isAudioFile(asset)) {
          final filename = asset.substring('assets/music/'.length);
          addTrack(id: asset, title: filename, assetPath: asset);
        }
      }
    } catch (e) {
      debugPrint('AssetManifest query note: $e');
    }

    // 2. Scan strictly assets/music on the local filesystem
    final searchDirs = [
      Directory('assets/music'),
      Directory('example/assets/music'),
    ];
    for (final dir in searchDirs) {
      if (dir.existsSync()) {
        for (final entity in dir.listSync()) {
          if (entity is File && _isAudioFile(entity.path)) {
            final filename = entity.path.split(RegExp(r'[/\\]')).last;
            addTrack(
              id: entity.path,
              title: filename,
              filePath: entity.path,
              assetPath: 'assets/music/$filename',
            );
          }
        }
      }
    }

    // Fallback: If no assets found, use the autogenerated sine wave as fallback
    if (tracks.isEmpty) {
      tracks.add(
        const AudioTrack(
          id: 'fallback_generated',
          title: 'Fallback Autogenerado (440Hz Sine)',
          isGenerated: true,
        ),
      );
    } else {
      // Also provide the option to switch to the generated test tone
      tracks.add(
        const AudioTrack(
          id: 'test_tone_generated',
          title: 'Tono autogenerado (440Hz Sine)',
          isGenerated: true,
        ),
      );
    }

    _availableTracks = tracks;
    final initialTrack = tracks.first;
    _selectedTrack = initialTrack;

    try {
      final path = await _resolveTrackPath(initialTrack);
      _samplePath = path;
      if (path.isNotEmpty) {
        await _player.action.open(path);
        _runAnalysis();
      }
    } catch (e, st) {
      debugPrint('Initial track open note: $e\n$st');
    } finally {
      if (mounted) {
        setState(() {
          _isReady = true;
        });
      }
    }
  }

  Future<Directory> _getTempDirectory() async {
    try {
      return await getTemporaryDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  Future<String> _resolveTrackPath(AudioTrack track) async {
    if (track.isGenerated) {
      return _generateFallbackAudio();
    }

    // 1. If explicit file path is provided and exists on disk
    if (track.filePath != null && File(track.filePath!).existsSync()) {
      return track.filePath!;
    }

    // 2. If asset path is provided, try extracting from Flutter rootBundle
    if (track.assetPath != null) {
      try {
        final byteData = await rootBundle.load(track.assetPath!);
        final tempDir = await _getTempDirectory();
        final fileName = track.assetPath!.split(RegExp(r'[/\\]')).last;
        final tempFile = File('${tempDir.path}/$fileName');
        if (!tempFile.existsSync() ||
            tempFile.lengthSync() != byteData.lengthInBytes) {
          await tempFile.writeAsBytes(
            byteData.buffer.asUint8List(
              byteData.offsetInBytes,
              byteData.lengthInBytes,
            ),
            flush: true,
          );
        }
        return tempFile.path;
      } catch (e) {
        debugPrint('Asset extraction error (${track.assetPath}): $e');
        // Fall through to filesystem checks
      }
    }

    // 3. Check filesystem locations
    final filename = (track.assetPath ?? track.id).split(RegExp(r'[/\\]')).last;
    final possiblePaths = [
      'assets/music/$filename',
      'example/assets/music/$filename',
    ];
    for (final path in possiblePaths) {
      final file = File(path);
      if (file.existsSync()) {
        return file.path;
      }
    }

    // 4. Ultimate fallback: generate audio
    return _generateFallbackAudio();
  }

  Future<String> _generateFallbackAudio() async {
    try {
      final tempDir = await _getTempDirectory();
      final file = File('${tempDir.path}/miniaudio_demo_440hz_generated.wav');

      if (!file.existsSync()) {
        const sampleRate = 44100;
        const durationSeconds = 10;
        const numSamples = sampleRate * durationSeconds;
        const dataSize = numSamples * 2;
        final byteData = ByteData(44 + dataSize);

        byteData.setUint8(0, 0x52); // R
        byteData.setUint8(1, 0x49); // I
        byteData.setUint8(2, 0x46); // F
        byteData.setUint8(3, 0x46); // F
        byteData.setUint32(4, 36 + dataSize, Endian.little);
        byteData.setUint8(8, 0x57); // W
        byteData.setUint8(9, 0x41); // A
        byteData.setUint8(10, 0x56); // V
        byteData.setUint8(11, 0x45); // E
        byteData.setUint8(12, 0x66); // f
        byteData.setUint8(13, 0x6D); // m
        byteData.setUint8(14, 0x74); // t
        byteData.setUint8(15, 0x20); // ' '
        byteData.setUint32(16, 16, Endian.little);
        byteData.setUint16(20, 1, Endian.little);
        byteData.setUint16(22, 1, Endian.little);
        byteData.setUint32(24, sampleRate, Endian.little);
        byteData.setUint32(28, sampleRate * 2, Endian.little);
        byteData.setUint16(32, 2, Endian.little);
        byteData.setUint16(34, 16, Endian.little);
        byteData.setUint8(36, 0x64); // d
        byteData.setUint8(37, 0x61); // a
        byteData.setUint8(38, 0x74); // t
        byteData.setUint8(39, 0x61); // a
        byteData.setUint32(40, dataSize, Endian.little);

        for (int i = 0; i < numSamples; i++) {
          final t = i / sampleRate;
          final sampleVal = (sin(2 * pi * 440.0 * t) * 32767 * 0.7).toInt();
          byteData.setInt16(
            44 + i * 2,
            sampleVal.clamp(-32768, 32767),
            Endian.little,
          );
        }

        await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      }

      return file.path;
    } catch (e) {
      debugPrint('Error generating fallback audio: $e');
      return '';
    }
  }

  Future<void> _selectTrack(AudioTrack track) async {
    setState(() {
      _isLoadingTrack = true;
      _selectedTrack = track;
    });

    try {
      final wasPlaying = _player.state.playing;
      await _player.action.stop();
      final path = await _resolveTrackPath(track);
      _samplePath = path;
      _analysisResult = null;
      await _player.action.open(path);
      _runAnalysis();
      if (wasPlaying) {
        await _player.action.play();
      }
    } catch (e) {
      debugPrint('Error switching track: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingTrack = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _deviceListSub?.cancel();
    _equalizerSub?.cancel();
    _silenceConfigSub?.cancel();
    _volumeSub?.cancel();
    _rateSub?.cancel();
    _pitchSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('miniaudio_player Demo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildPlaybackCard(),
            const SizedBox(height: 16),
            _buildVisualizerCard(),
            const SizedBox(height: 16),
            _buildWaveformAndAnalysisCard(),
            const SizedBox(height: 16),
            _buildSilenceSkipCard(),
            const SizedBox(height: 16),
            _buildDspControlsCard(),
            const SizedBox(height: 16),
            _buildEqualizerCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaybackCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<AudioTrack>(
                    key: ValueKey(_selectedTrack),
                    initialValue: _selectedTrack,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Pista de audio (Assets)',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      prefixIcon: Icon(Icons.library_music),
                    ),
                    items: _availableTracks.map((track) {
                      final isFallback = track.isGenerated;
                      return DropdownMenuItem<AudioTrack>(
                        value: track,
                        child: Row(
                          children: [
                            Icon(
                              isFallback
                                  ? Icons.graphic_eq
                                  : Icons.audiotrack,
                              size: 18,
                              color: isFallback
                                  ? Colors.amberAccent
                                  : Colors.tealAccent,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                track.title,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: _isLoadingTrack
                        ? null
                        : (track) {
                            if (track != null && track != _selectedTrack) {
                              _selectTrack(track);
                            }
                          },
                  ),
                ),
                if (_isLoadingTrack) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  'Archivo: ${_samplePath?.split(RegExp(r"[/\\]")).last ?? ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                StreamBuilder<int>(
                  stream: _player.stream.audioBitrate,
                  initialData: _player.state.audioBitrate,
                  builder: (context, snapshot) {
                    final bitrate = snapshot.data ?? 0;
                    if (bitrate <= 0) return const SizedBox.shrink();
                    final kbps = (bitrate / 1000).round();
                    return Chip(
                      labelPadding:
                          const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.speed, size: 14),
                      label: Text(
                        '$kbps kbps',
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  },
                ),
                StreamBuilder<bool>(
                  stream: _player.stream.playing,
                  initialData: _player.state.playing,
                  builder: (context, snapshot) {
                    final isPlaying = snapshot.data ?? false;
                    return Chip(
                      labelPadding:
                          const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        isPlaying ? 'PLAYING' : 'STOPPED / PAUSED',
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            StreamBuilder<Duration>(
              stream: _player.stream.position,
              initialData: _player.state.position,
              builder: (context, posSnapshot) {
                final pos = posSnapshot.data ?? Duration.zero;
                final dur = _player.state.duration;
                final maxMs = dur.inMilliseconds > 0
                    ? dur.inMilliseconds.toDouble()
                    : 1.0;
                final currentMs = pos.inMilliseconds.toDouble().clamp(
                  0.0,
                  maxMs,
                );

                return Column(
                  children: [
                    Slider(
                      value: (_dragPositionMs ?? currentMs).clamp(0.0, maxMs),
                      max: maxMs,
                      onChangeStart: (val) {
                        setState(() => _dragPositionMs = val);
                      },
                      onChanged: (val) {
                        setState(() => _dragPositionMs = val);
                      },
                      onChangeEnd: (val) {
                        _player.action.seek(
                          Duration(milliseconds: val.toInt()),
                        );
                        setState(() => _dragPositionMs = null);
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            _formatDuration(
                              _dragPositionMs != null
                                  ? Duration(
                                      milliseconds: _dragPositionMs!.toInt(),
                                    )
                                  : pos,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            _formatDuration(dur),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            StreamBuilder<bool>(
              stream: _player.stream.playing,
              initialData: _player.state.playing,
              builder: (context, snapshot) {
                final isPlaying = snapshot.data ?? false;

                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      iconSize: 40,
                      icon: const Icon(Icons.stop),
                      onPressed: () => _player.action.stop(),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      iconSize: 48,
                      icon: Icon(
                        isPlaying ? Icons.pause_circle : Icons.play_circle,
                      ),
                      onPressed: () {
                        if (isPlaying) {
                          _player.action.pause();
                        } else {
                          _player.action.play();
                        }
                      },
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDspControlsCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.tune, color: Colors.deepPurpleAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'DSP & Audio Processing Chain',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Real-time low-latency DSP chain (0 heap allocations in RT audio thread)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                  ),
            ),
            const SizedBox(height: 16),
            Text(
              'Playback Adjustments',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Colors.deepPurpleAccent,
                  ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(width: 70, child: Text('Volume')),
                Expanded(
                  child: Slider(
                    value: _volume,
                    min: 0.0,
                    max: 2.0,
                    divisions: 20,
                    label: '${(_volume * 100).toInt()}%',
                    onChanged: (v) {
                      setState(() => _volume = v);
                      _player.action.setVolume(v);
                    },
                  ),
                ),
                SizedBox(width: 45, child: Text('${(_volume * 100).toInt()}%')),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 70, child: Text('Rate')),
                Expanded(
                  child: Slider(
                    value: _rate,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: '${_rate.toStringAsFixed(1)}x',
                    onChanged: (v) {
                      setState(() => _rate = v);
                      _player.action.setRate(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 45,
                  child: Text('${_rate.toStringAsFixed(1)}x'),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 70, child: Text('Pitch')),
                Expanded(
                  child: Slider(
                    value: _pitch,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: '${_pitch.toStringAsFixed(1)}x',
                    onChanged: (v) {
                      setState(() => _pitch = v);
                      _player.action.setPitch(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 45,
                  child: Text('${_pitch.toStringAsFixed(1)}x'),
                ),
              ],
            ),
            const Divider(height: 24),
            Text(
              'DSP Signal Chain',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Colors.deepPurpleAccent,
                  ),
            ),
            const SizedBox(height: 8),
            StreamBuilder<bool>(
              stream: _player.stream.limiterEnabled,
              initialData: _player.state.limiterEnabled,
              builder: (context, snapshot) {
                final isLimiterOn = snapshot.data ?? false;
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(
                    Icons.shield_outlined,
                    color: Colors.deepPurpleAccent,
                  ),
                  title: const Text('True-Peak Limiter Guard'),
                  subtitle: const Text(
                    'Branchless soft-knee limiter (THD < 0.01% under 0.95)',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: isLimiterOn,
                  activeThumbColor: Colors.deepPurpleAccent,
                  onChanged: (val) {
                    _player.action.setLimiter(val);
                  },
                );
              },
            ),
            const Divider(height: 16),
            StreamBuilder<CrossfeedMode>(
              stream: _player.stream.crossfeed,
              initialData: _player.state.crossfeed,
              builder: (context, snapshot) {
                final currentMode = snapshot.data ?? CrossfeedMode.off;
                return LayoutBuilder(
                  builder: (context, constraints) {
                    Widget buildDropdown() {
                      return DropdownButtonFormField<CrossfeedMode>(
                        key: ValueKey(currentMode),
                        initialValue: currentMode,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: CrossfeedMode.off,
                            child: Text(
                              'Off (Stereo)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DropdownMenuItem(
                            value: CrossfeedMode.moffatBauer,
                            child: Text(
                              'Moffat-Bauer (4.5 dB)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DropdownMenuItem(
                            value: CrossfeedMode.chuMoy,
                            child: Text(
                              'Chu Moy (6.0 dB)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        onChanged: (mode) {
                          if (mode != null) {
                            _player.action.setCrossfeed(mode);
                          }
                        },
                      );
                    }

                    if (constraints.maxWidth < 480) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.headphones,
                                size: 22,
                                color: Colors.deepPurpleAccent,
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Headphone Crossfeed (BS2B)',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w500),
                                    ),
                                    Text(
                                      'Reduces headphone listening fatigue with acoustic binaural feed',
                                      style: TextStyle(
                                          fontSize: 11, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: buildDropdown(),
                          ),
                        ],
                      );
                    }

                    return Row(
                      children: [
                        const Icon(
                          Icons.headphones,
                          size: 22,
                          color: Colors.deepPurpleAccent,
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Headphone Crossfeed (BS2B)',
                                style: TextStyle(fontWeight: FontWeight.w500),
                              ),
                              Text(
                                'Reduces headphone listening fatigue with acoustic binaural feed',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 220,
                          child: buildDropdown(),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            const Divider(height: 16),
            StreamBuilder<bool>(
              stream: _player.stream.mono,
              initialData: _player.state.mono,
              builder: (context, snapshot) {
                final isMono = snapshot.data ?? false;
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(
                    Icons.speaker_group_outlined,
                    color: Colors.deepPurpleAccent,
                  ),
                  title: const Text('Mono Downmix'),
                  subtitle: const Text(
                    'Sum stereo channels (L+R)/2 for single speaker or accessibility',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: isMono,
                  activeThumbColor: Colors.deepPurpleAccent,
                  onChanged: (val) {
                    _player.action.setMono(val);
                  },
                );
              },
            ),
            const Divider(height: 16),
            StreamBuilder<double>(
              stream: _player.stream.balance,
              initialData: _player.state.balance,
              builder: (context, snapshot) {
                final currentBalance = snapshot.data ?? 0.0;
                String panLabel;
                if (currentBalance.abs() < 0.05) {
                  panLabel = 'Center (0.0)';
                } else if (currentBalance < 0) {
                  panLabel = 'L ${(currentBalance.abs() * 100).toInt()}%';
                } else {
                  panLabel = 'R ${(currentBalance * 100).toInt()}%';
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text('Stereo Balance: $panLabel'),
                        ),
                        if (currentBalance.abs() >= 0.05)
                          IconButton(
                            icon: const Icon(Icons.center_focus_strong, size: 18),
                            tooltip: 'Center Balance',
                            onPressed: () => _player.action.setBalance(0.0),
                          ),
                      ],
                    ),
                    Row(
                      children: [
                        const Text(
                          'L',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: currentBalance.clamp(-1.0, 1.0),
                            min: -1.0,
                            max: 1.0,
                            divisions: 20,
                            label: panLabel,
                            onChanged: (val) {
                              _player.action.setBalance(val);
                            },
                          ),
                        ),
                        const Text(
                          'R',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
            const Divider(height: 16),
            StreamBuilder<double>(
              stream: _player.stream.preamp,
              initialData: _player.state.preamp,
              builder: (context, snapshot) {
                final currentPreamp = snapshot.data ?? 0.0;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Preamp Gain: ${currentPreamp > 0 ? "+" : ""}${currentPreamp.toStringAsFixed(1)} dB',
                          ),
                        ),
                        if (currentPreamp.abs() > 0.01)
                          IconButton(
                            icon: const Icon(Icons.refresh, size: 18),
                            tooltip: 'Reset Preamp to 0 dB',
                            onPressed: () => _player.action.setPreamp(0.0),
                          ),
                      ],
                    ),
                    Slider(
                      value: currentPreamp.clamp(-12.0, 12.0),
                      min: -12.0,
                      max: 12.0,
                      divisions: 24,
                      label: '${currentPreamp.toStringAsFixed(1)} dB',
                      onChanged: (val) {
                        _player.action.setPreamp(val);
                      },
                    ),
                  ],
                );
              },
            ),
            const Divider(height: 16),
            StreamBuilder<bool>(
              stream: _player.stream.spatializerEnabled,
              initialData: _player.state.spatializerEnabled,
              builder: (context, snapEnabled) {
                final isSpatialOn = snapEnabled.data ?? false;
                return Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(
                        Icons.surround_sound,
                        color: Colors.deepPurpleAccent,
                      ),
                      title: const Text('Stereo Spatializer (Widener)'),
                      subtitle: const Text(
                        'Mid/Side spatial field expansion processor',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: isSpatialOn,
                      activeThumbColor: Colors.deepPurpleAccent,
                      onChanged: (val) {
                        _player.action.setSpatializer(
                          enabled: val,
                          width: _player.state.spatializerWidth,
                        );
                      },
                    ),
                    if (isSpatialOn)
                      StreamBuilder<double>(
                        stream: _player.stream.spatializerWidth,
                        initialData: _player.state.spatializerWidth,
                        builder: (context, snapWidth) {
                          final width = snapWidth.data ?? 1.3;
                          return Row(
                            children: [
                              const SizedBox(
                                width: 70,
                                child: Text(
                                  'Width',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              Expanded(
                                child: Slider(
                                  value: width.clamp(1.0, 2.0),
                                  min: 1.0,
                                  max: 2.0,
                                  divisions: 10,
                                  label: '${width.toStringAsFixed(1)}x',
                                  onChanged: (w) {
                                    _player.action.setSpatializer(
                                      enabled: true,
                                      width: w,
                                    );
                                  },
                                ),
                              ),
                              SizedBox(
                                width: 45,
                                child: Text('${width.toStringAsFixed(1)}x'),
                              ),
                            ],
                          );
                        },
                      ),
                  ],
                );
              },
            ),
            const Divider(height: 16),
            StreamBuilder<Reverb>(
              stream: _player.stream.reverb,
              initialData: _player.state.reverb,
              builder: (context, snapReverb) {
                final reverb = snapReverb.data ?? Reverb.off;
                return Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(
                        Icons.waves,
                        color: Colors.deepPurpleAccent,
                      ),
                      title: const Text('Algorithmic Reverb'),
                      subtitle: const Text(
                        'Studio Freeverb physical acoustic simulation',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: reverb.enabled,
                      activeThumbColor: Colors.deepPurpleAccent,
                      onChanged: (val) {
                        _player.action.setReverb(
                          val
                              ? (reverb.roomSize > 0.05
                                  ? reverb.copyWith(enabled: true)
                                  : Reverb.concertHall)
                              : Reverb.off,
                        );
                      },
                    ),
                    if (reverb.enabled) ...[
                      Row(
                        children: [
                          const SizedBox(
                            width: 70,
                            child: Text(
                              'Preset',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          Expanded(
                            child: Builder(
                              builder: (context) {
                                final presetKey = Reverb.presets.entries
                                    .firstWhere(
                                      (e) => e.value == reverb,
                                      orElse: () => const MapEntry('Custom', Reverb.off),
                                    )
                                    .key;
                                return DropdownButtonFormField<String>(
                                  key: ValueKey(presetKey),
                                  initialValue: presetKey,
                                  decoration: const InputDecoration(
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                ...Reverb.presets.keys
                                    .where((k) => k != 'Off')
                                    .map(
                                      (k) => DropdownMenuItem(
                                        value: k,
                                        child: Text(k),
                                      ),
                                    ),
                                if (!Reverb.presets.values.contains(reverb))
                                  const DropdownMenuItem(
                                    value: 'Custom',
                                    child: Text('Custom'),
                                  ),
                              ],
                              onChanged: (selected) {
                                if (selected != null &&
                                    Reverb.presets.containsKey(selected)) {
                                  _player.action.setReverb(
                                    Reverb.presets[selected]!,
                                  );
                                }
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const SizedBox(
                            width: 70,
                            child: Text(
                              'Room Size',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: reverb.roomSize.clamp(0.0, 1.0),
                              min: 0.0,
                              max: 1.0,
                              divisions: 20,
                              label: '${(reverb.roomSize * 100).toStringAsFixed(0)}%',
                              onChanged: (v) {
                                _player.action.configureReverb(roomSize: v);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 45,
                            child: Text(
                              '${(reverb.roomSize * 100).toStringAsFixed(0)}%',
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const SizedBox(
                            width: 70,
                            child: Text(
                              'Damping',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: reverb.damping.clamp(0.0, 1.0),
                              min: 0.0,
                              max: 1.0,
                              divisions: 20,
                              label: '${(reverb.damping * 100).toStringAsFixed(0)}%',
                              onChanged: (v) {
                                _player.action.configureReverb(damping: v);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 45,
                            child: Text(
                              '${(reverb.damping * 100).toStringAsFixed(0)}%',
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const SizedBox(
                            width: 70,
                            child: Text(
                              'Wet',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: reverb.wet.clamp(0.0, 1.0),
                              min: 0.0,
                              max: 1.0,
                              divisions: 20,
                              label: '${(reverb.wet * 100).toStringAsFixed(0)}%',
                              onChanged: (v) {
                                _player.action.configureReverb(wet: v);
                              },
                            ),
                          ),
                          SizedBox(
                            width: 45,
                            child: Text(
                              '${(reverb.wet * 100).toStringAsFixed(0)}%',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
            const Divider(height: 24),
            Text(
              'Hardware & Output Device',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Colors.deepPurpleAccent,
                  ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(width: 70, child: Text('Buffer Size')),
                Expanded(
                  child: StreamBuilder<int>(
                    stream: _player.stream.bufferSize,
                    initialData: _player.state.bufferSize,
                    builder: (context, snapshot) {
                      final currentBuffer = snapshot.data ?? 0;
                      final standardValues = [0, 256, 512, 1024, 2048, 4096];
                      final value = standardValues.contains(currentBuffer)
                          ? currentBuffer
                          : 0;

                      return DropdownButtonFormField<int>(
                        key: ValueKey(value),
                        initialValue: value,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 0,
                            child: Text(
                              '0 (Native Default)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DropdownMenuItem(
                            value: 256,
                            child: Text(
                              '256 frames (~5.8ms @ 44.1kHz)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DropdownMenuItem(
                            value: 512,
                            child: Text(
                              '512 frames (~11.6ms @ 44.1kHz)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DropdownMenuItem(
                            value: 1024,
                            child: Text(
                              '1024 frames (~23.2ms @ 44.1kHz)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DropdownMenuItem(
                            value: 2048,
                            child: Text(
                              '2048 frames (~46.4ms @ 44.1kHz)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DropdownMenuItem(
                            value: 4096,
                            child: Text(
                              '4096 frames (~92.8ms @ 44.1kHz)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        onChanged: (newBuf) {
                          if (newBuf != null) {
                            _player.action.setBufferSize(newBuf);
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                const SizedBox(width: 70, child: Text('Output')),
                Expanded(
                  child: StreamBuilder<AudioDevice>(
                    stream: _player.stream.audioDevice,
                    initialData: _player.state.audioDevice,
                    builder: (context, snapshot) {
                      final currentDev =
                          snapshot.data ?? _player.state.audioDevice;
                      final items = <AudioDevice>{
                        ..._audioDevices,
                        currentDev,
                      }.toList();

                      AudioDevice? selectedValue;
                      for (final item in items) {
                        if (item == currentDev) {
                          selectedValue = item;
                          break;
                        }
                      }
                      selectedValue ??= items.isNotEmpty ? items.first : null;

                      return DropdownButtonFormField<AudioDevice>(
                        key: ValueKey(selectedValue),
                        initialValue: selectedValue,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        items: items.map((dev) {
                          return DropdownMenuItem<AudioDevice>(
                            value: dev,
                            child: Text(
                              dev.displayName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: (newDev) async {
                          if (newDev != null) {
                            try {
                              final success = await _player.action.setDevice(
                                newDev,
                              );
                              if (!success && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Device "${newDev.name}" is unavailable or disconnected. Falling back to default.',
                                    ),
                                    backgroundColor: Colors.orange,
                                    duration: const Duration(seconds: 3),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Failed to set device: $e'),
                                    backgroundColor: Colors.red,
                                    duration: const Duration(seconds: 3),
                                  ),
                                );
                              }
                            }
                            _refreshAudioDevices();
                          }
                        },
                      );
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Refresh Audio Devices',
                  onPressed: _refreshAudioDevices,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEqualizerCard() {
    final bands = [
      (
        '31Hz',
        _currentEqualizer.hz31,
        (double v) => _currentEqualizer.copyWith(hz31: v),
      ),
      (
        '63Hz',
        _currentEqualizer.hz63,
        (double v) => _currentEqualizer.copyWith(hz63: v),
      ),
      (
        '125Hz',
        _currentEqualizer.hz125,
        (double v) => _currentEqualizer.copyWith(hz125: v),
      ),
      (
        '250Hz',
        _currentEqualizer.hz250,
        (double v) => _currentEqualizer.copyWith(hz250: v),
      ),
      (
        '500Hz',
        _currentEqualizer.hz500,
        (double v) => _currentEqualizer.copyWith(hz500: v),
      ),
      (
        '1kHz',
        _currentEqualizer.hz1k,
        (double v) => _currentEqualizer.copyWith(hz1k: v),
      ),
      (
        '2kHz',
        _currentEqualizer.hz2k,
        (double v) => _currentEqualizer.copyWith(hz2k: v),
      ),
      (
        '4kHz',
        _currentEqualizer.hz4k,
        (double v) => _currentEqualizer.copyWith(hz4k: v),
      ),
      (
        '8kHz',
        _currentEqualizer.hz8k,
        (double v) => _currentEqualizer.copyWith(hz8k: v),
      ),
      (
        '16kHz',
        _currentEqualizer.hz16k,
        (double v) => _currentEqualizer.copyWith(hz16k: v),
      ),
    ];

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.graphic_eq, color: Colors.tealAccent),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '10-Band Equalizer (ISO 266)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('Flat', style: TextStyle(fontSize: 12)),
                      onPressed: () {
                        setState(() {
                          _currentEqualizer = Equalizer.flat;
                          _selectedPreset = 'flat';
                        });
                        _player.action.setEqualizer(Equalizer.flat);
                      },
                    ),
                    SizedBox(
                      width: 140,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(_selectedPreset),
                        initialValue: _selectedPreset,
                        isExpanded: true,
                        hint: const Text('Presets', style: TextStyle(fontSize: 12)),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontSize: 12),
                        items: const [
                          DropdownMenuItem(
                            value: 'flat',
                            child: Text('Flat', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'rock',
                            child: Text('Rock', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'pop',
                            child: Text('Pop', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'jazz',
                            child: Text('Jazz', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'classical',
                            child: Text(
                              'Classical',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'bassBoost',
                            child: Text(
                              'Bass Boost',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                        onChanged: (preset) {
                          if (preset == null) return;
                          Equalizer target;
                          switch (preset) {
                            case 'rock':
                              target = Equalizer.rock;
                            case 'pop':
                              target = Equalizer.pop;
                            case 'jazz':
                              target = Equalizer.jazz;
                            case 'classical':
                              target = Equalizer.classical;
                            case 'bassBoost':
                              target = Equalizer.bassBoost;
                            default:
                              target = Equalizer.flat;
                          }
                          setState(() {
                            _currentEqualizer = target;
                            _selectedPreset = preset;
                          });
                          _player.action.setEqualizer(target);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Text(
              'Preferred 1/1 octave center frequencies with RBJ peaking/shelving biquads',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                  ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 190,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: bands.map((band) {
                    final val = band.$2;
                    final isPositive = val > 0.05;
                    final isNegative = val < -0.05;
                    final color = isPositive
                        ? Colors.tealAccent
                        : (isNegative ? Colors.orangeAccent : Colors.grey);

                    return SizedBox(
                      width: 52,
                      child: Column(
                        children: [
                          Text(
                            '${val > 0 ? "+" : ""}${val.toStringAsFixed(1)}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: color,
                            ),
                          ),
                          Expanded(
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: Slider(
                                value: val.clamp(-24.0, 24.0),
                                min: -24.0,
                                max: 24.0,
                                activeColor: color,
                                onChanged: (newVal) {
                                  final updated = band.$3(newVal);
                                  setState(() {
                                    _currentEqualizer = updated;
                                    _selectedPreset = _detectPreset(updated);
                                  });
                                  _player.action.setEqualizer(updated);
                                },
                              ),
                            ),
                          ),
                          Text(
                            band.$1,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVisualizerCard() {
    final bandLabels = [
      '31Hz',
      '63Hz',
      '125Hz',
      '250Hz',
      '500Hz',
      '1kHz',
      '2kHz',
      '4kHz',
      '8kHz',
      '16kHz',
    ];

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: StreamBuilder<bool>(
          stream: _player.stream.visualizerEnabled,
          initialData: _player.state.visualizerEnabled,
          builder: (context, enabledSnapshot) {
            final isEnabled = enabledSnapshot.data ?? true;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.equalizer, color: Colors.cyanAccent),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Real-Time Reactive Visualizer',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          isEnabled ? 'ON' : 'OFF',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isEnabled ? Colors.cyanAccent : Colors.grey,
                          ),
                        ),
                        Switch(
                          value: isEnabled,
                          activeThumbColor: Colors.cyanAccent,
                          onChanged: (val) {
                            _player.action.setVisualizerEnabled(val);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                Text(
                  '10-band hardware BPF filter bank & VU meters in C engine (<0.5% CPU)',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                ),
                const SizedBox(height: 16),
                StreamBuilder<VisualizerData>(
                  stream: _player.stream.visualizer,
                  initialData: _player.state.visualizer,
                  builder: (context, snapshot) {
                    final data = isEnabled
                        ? (snapshot.data ?? VisualizerData.empty())
                        : VisualizerData.empty();
                    final bands = data.bands;

                    return AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      opacity: isEnabled ? 1.0 : 0.38,
                      child: Column(
                        children: [
                          // Reactive Pulsing Sound Wave Bar
                          Container(
                            height: 28,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.graphic_eq,
                                  size: 16,
                                  color: Colors.cyanAccent,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final pulseWidth =
                                          (!isEnabled || data.rms == 0.0)
                                              ? 0.0
                                              : constraints.maxWidth *
                                                  data.rms.clamp(0.04, 1.0);
                                      return Stack(
                                        alignment: Alignment.centerLeft,
                                        children: [
                                          Container(
                                            height: 6,
                                            width: constraints.maxWidth,
                                            decoration: BoxDecoration(
                                              color: Colors.white10,
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          ),
                                          AnimatedContainer(
                                            duration: const Duration(
                                              milliseconds: 33,
                                            ),
                                            height:
                                                (6 + (data.peak * 10)).clamp(
                                              6.0,
                                              16.0,
                                            ),
                                            width: pulseWidth,
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [
                                                  Colors.cyanAccent,
                                                  Colors.purpleAccent,
                                                  if (data.peak > 0.8)
                                                    Colors.redAccent,
                                                ],
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.cyanAccent
                                                      .withValues(
                                                    alpha:
                                                        (0.4 * data.rms).clamp(
                                                      0.0,
                                                      1.0,
                                                    ),
                                                  ),
                                                  blurRadius: 6,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'RMS ${(data.rms * 100).toInt()}%',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          // 10-Band Frequency Spectrum Bars
                          SizedBox(
                            height: 120,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: List.generate(10, (i) {
                                final val = bands[i].clamp(0.0, 1.0);
                                final label = bandLabels[i];
                                return Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2.0,
                                    ),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Expanded(
                                          child: Align(
                                            alignment: Alignment.bottomCenter,
                                            child: AnimatedContainer(
                                              duration: const Duration(
                                                milliseconds: 33,
                                              ),
                                              height:
                                                  (90 * val).clamp(2.0, 90.0),
                                              width: double.infinity,
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                  3,
                                                ),
                                                gradient: LinearGradient(
                                                  begin: Alignment.bottomCenter,
                                                  end: Alignment.topCenter,
                                                  colors: [
                                                    Colors.tealAccent,
                                                    Colors.cyanAccent,
                                                    if (val > 0.6)
                                                      Colors.purpleAccent,
                                                    if (val > 0.85)
                                                      Colors.amberAccent,
                                                  ],
                                                ),
                                                boxShadow: [
                                                  if (val > 0.2)
                                                    BoxShadow(
                                                      color: Colors.cyanAccent
                                                          .withValues(
                                                        alpha: (0.35 * val)
                                                            .clamp(
                                                          0.0,
                                                          1.0,
                                                        ),
                                                      ),
                                                      blurRadius: 4,
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          label,
                                          style: const TextStyle(
                                            fontSize: 9,
                                            color: Colors.grey,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                          const SizedBox(height: 14),
                          // Stereo VU Meter & Peak
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const SizedBox(
                                          width: 16,
                                          child: Text(
                                            'L',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(4),
                                            child: LinearProgressIndicator(
                                              value: data.left.clamp(0.0, 1.0),
                                              minHeight: 7,
                                              backgroundColor: Colors.white12,
                                              color: data.left > 0.85
                                                  ? Colors.redAccent
                                                  : Colors.cyanAccent,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        const SizedBox(
                                          width: 16,
                                          child: Text(
                                            'R',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(4),
                                            child: LinearProgressIndicator(
                                              value: data.right.clamp(0.0, 1.0),
                                              minHeight: 7,
                                              backgroundColor: Colors.white12,
                                              color: data.right > 0.85
                                                  ? Colors.redAccent
                                                  : Colors.cyanAccent,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    'Peak: ${(data.peak * 100).toInt()}%',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: data.peak > 0.9
                                          ? Colors.redAccent
                                          : null,
                                    ),
                                  ),
                                  Text(
                                    'RMS: ${(data.rms * 100).toInt()}%',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildWaveformAndAnalysisCard() {
    final res = _analysisResult;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.waves, color: Colors.purpleAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Waveform & ReplayGain Analysis',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_isAnalyzing)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: 'Re-analyze Track',
                    onPressed: _runAnalysis,
                  ),
              ],
            ),
            Text(
              'Unified single-pass native C analysis (MiniaudioPlayer.analyzeAudio)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                  ),
            ),
            const SizedBox(height: 12),
            if (res == null && _isAnalyzing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24.0),
                child: Center(
                  child: Text('Analyzing track acoustic properties...'),
                ),
              )
            else if (res != null) ...[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      'Loudness: ${res.replayGain?.lufs.toStringAsFixed(1) ?? "N/A"} LUFS',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      'Gain: ${res.replayGain?.gainDb.toStringAsFixed(1) ?? "0.0"} dB',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      'True Peak: ${res.replayGain?.peak.toStringAsFixed(2) ?? res.peak.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (res.replayGain != null) ...[
                StreamBuilder<ReplayGainConfig>(
                  stream: _player.stream.replayGain,
                  initialData: _player.state.replayGain,
                  builder: (context, snapshot) {
                    final rg = snapshot.data ?? const ReplayGainConfig();
                    final isActive = rg.enabled;

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isActive
                              ? Colors.purpleAccent.withValues(alpha: 0.5)
                              : Colors.white12,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isActive
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                    size: 16,
                                    color: isActive
                                        ? Colors.purpleAccent
                                        : Colors.grey,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    isActive
                                        ? 'Native ReplayGain: ACTIVE (${rg.gainDb.toStringAsFixed(1)} dB)'
                                        : 'Native ReplayGain: BYPASSED',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: isActive
                                          ? Colors.purpleAccent
                                          : Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Checkbox(
                                    value: _replayGainPreventClipping,
                                    activeColor: Colors.purpleAccent,
                                    onChanged: (val) {
                                      setState(() {
                                        _replayGainPreventClipping =
                                            val ?? true;
                                      });
                                      if (rg.enabled) {
                                        _player.action.setReplayGain(
                                          gainDb: res.replayGain!.gainDb,
                                          peak: res.replayGain!.peak,
                                          preventClipping:
                                              _replayGainPreventClipping,
                                        );
                                      }
                                    },
                                  ),
                                  const Text(
                                    'Clip Defense',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              ElevatedButton.icon(
                                icon: const Icon(Icons.bolt, size: 16),
                                label: const Text('Engage Native ReplayGain'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.purple.shade700,
                                  foregroundColor: Colors.white,
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  _player.action.setReplayGain(
                                    gainDb: res.replayGain!.gainDb,
                                    peak: res.replayGain!.peak,
                                    preventClipping:
                                        _replayGainPreventClipping,
                                  );
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Native ReplayGain applied (${res.replayGain!.gainDb.toStringAsFixed(1)} dB, anti-clipping: $_replayGainPreventClipping)',
                                        ),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  }
                                },
                              ),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.clear, size: 16),
                                label: const Text('Bypass / Clear'),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  _player.action.clearReplayGain();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Native ReplayGain bypassed (unity gain 0 dB)',
                                        ),
                                        duration: Duration(seconds: 2),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 14),
              if (res.waveform != null && res.waveform!.points.isNotEmpty) ...[
                Text(
                  'Interactive Waveform Seekbar (Tap / Drag to Seek)',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
                const SizedBox(height: 8),
                StreamBuilder<Duration>(
                  stream: _player.stream.position,
                  initialData: _player.state.position,
                  builder: (context, posSnapshot) {
                    final pos = posSnapshot.data ?? Duration.zero;
                    final dur = _player.state.duration;
                    final progress = (dur.inMilliseconds > 0)
                        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(
                            0.0,
                            1.0,
                          )
                        : 0.0;

                    return LayoutBuilder(
                      builder: (context, constraints) {
                        void handleSeek(Offset localPosition) {
                          if (dur.inMilliseconds <= 0) return;
                          final frac = (localPosition.dx / constraints.maxWidth)
                              .clamp(0.0, 1.0);
                          final targetMs = (frac * dur.inMilliseconds).toInt();
                          _player.action.seek(Duration(milliseconds: targetMs));
                        }

                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (details) =>
                              handleSeek(details.localPosition),
                          onHorizontalDragUpdate: (details) =>
                              handleSeek(details.localPosition),
                          child: Container(
                            height: 60,
                            width: constraints.maxWidth,
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            child: CustomPaint(
                              size: Size(max(0.0, constraints.maxWidth - 16), 48),
                              painter: WaveformPainter(
                                points: res.waveform!.points,
                                progress: progress,
                                playedColor: Colors.purpleAccent,
                                unplayedColor: Colors.white24,
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ] else
              OutlinedButton.icon(
                icon: const Icon(Icons.analytics_outlined),
                label: const Text('Analyze Audio Track'),
                onPressed: _runAnalysis,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSilenceSkipCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: StreamBuilder<bool>(
          stream: _player.stream.skipSilence,
          initialData: _player.state.skipSilence,
          builder: (context, snapshot) {
            final isEnabled = snapshot.data ?? false;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.mic_off_outlined,
                          color: Colors.amberAccent,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Smart Silence Skipping',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          isEnabled ? 'ON' : 'OFF',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isEnabled ? Colors.amberAccent : Colors.grey,
                          ),
                        ),
                        Switch(
                          value: isEnabled,
                          activeThumbColor: Colors.amberAccent,
                          onChanged: (val) {
                            _player.action.setSkipSilence(
                              val,
                              mode: _silenceMode,
                              thresholdDb: _silenceThresholdDb,
                              minSilenceDuration:
                                  Duration(milliseconds: _minSilenceDurationMs),
                              padding:
                                  Duration(milliseconds: _silencePaddingMs),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                Text(
                  'Hardware RMS silence detection with micro-fade transitions',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                ),
                const SizedBox(height: 12),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: isEnabled ? 1.0 : 0.38,
                  child: IgnorePointer(
                    ignoring: !isEnabled,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Mode: ',
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonFormField<SilenceSkipMode>(
                                key: ValueKey(_silenceMode),
                                initialValue: _silenceMode,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: SilenceSkipMode.continuous,
                                    child: Text(
                                      'Continuous (In-Between Pauses)',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: SilenceSkipMode.trimEdges,
                                    child: Text(
                                      'Trim Edges (Intro & Outro)',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: SilenceSkipMode.all,
                                    child: Text(
                                      'All (Edges + In-Between Pauses)',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                                onChanged: isEnabled
                                    ? (newMode) {
                                        if (newMode != null) {
                                          setState(
                                              () => _silenceMode = newMode);
                                          if (_player.state.skipSilence) {
                                            _player.action.configureSilenceSkip(
                                              mode: newMode,
                                              thresholdDb: _silenceThresholdDb,
                                              minSilenceDuration: Duration(
                                                milliseconds:
                                                    _minSilenceDurationMs,
                                              ),
                                              padding: Duration(
                                                milliseconds:
                                                    _silencePaddingMs,
                                              ),
                                            );
                                          }
                                        }
                                      }
                                    : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Threshold: ${_silenceThresholdDb.toStringAsFixed(1)} dBFS',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Slider(
                          value: _silenceThresholdDb.clamp(-90.0, -10.0),
                          min: -90.0,
                          max: -10.0,
                          divisions: 80,
                          label:
                              '${_silenceThresholdDb.toStringAsFixed(1)} dBFS',
                          onChanged: isEnabled
                              ? (val) {
                                  setState(() => _silenceThresholdDb = val);
                                  if (_player.state.skipSilence) {
                                    _player.action.configureSilenceSkip(
                                      thresholdDb: val,
                                    );
                                  }
                                }
                              : null,
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Min Silence: $_minSilenceDurationMs ms',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Slider(
                                    value: _minSilenceDurationMs
                                        .toDouble()
                                        .clamp(50.0, 2000.0),
                                    min: 50.0,
                                    max: 2000.0,
                                    divisions: 39,
                                    label: '$_minSilenceDurationMs ms',
                                    onChanged: isEnabled
                                        ? (val) {
                                            setState(() =>
                                                _minSilenceDurationMs =
                                                    val.toInt());
                                            if (_player.state.skipSilence) {
                                              _player.action
                                                  .configureSilenceSkip(
                                                minSilenceDuration: Duration(
                                                  milliseconds: val.toInt(),
                                                ),
                                              );
                                            }
                                          }
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Padding: $_silencePaddingMs ms',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Slider(
                                    value: _silencePaddingMs
                                        .toDouble()
                                        .clamp(0.0, 250.0),
                                    min: 0.0,
                                    max: 250.0,
                                    divisions: 25,
                                    label: '$_silencePaddingMs ms',
                                    onChanged: isEnabled
                                        ? (val) {
                                            setState(() =>
                                                _silencePaddingMs =
                                                    val.toInt());
                                            if (_player.state.skipSilence) {
                                              _player.action
                                                  .configureSilenceSkip(
                                                padding: Duration(
                                                  milliseconds: val.toInt(),
                                                ),
                                              );
                                            }
                                          }
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            StreamBuilder<Duration>(
                              stream: _player.stream.silenceSavedDuration,
                              initialData: _player.state.silenceSavedDuration,
                              builder: (context, snapshot) {
                                final saved = snapshot.data ?? Duration.zero;
                                final savedSec =
                                    (saved.inMilliseconds / 1000.0)
                                        .toStringAsFixed(1);
                                return Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.timer_outlined,
                                      size: 16,
                                      color: Colors.amberAccent,
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        'Time saved: $savedSec s (${saved.inMilliseconds} ms)',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.restart_alt, size: 14),
                              label: const Text(
                                'Defaults',
                                style: TextStyle(fontSize: 11),
                              ),
                              onPressed: isEnabled
                                  ? () {
                                      setState(() {
                                        _silenceThresholdDb = -45.0;
                                        _minSilenceDurationMs = 300;
                                        _silencePaddingMs = 50;
                                      });
                                      if (_player.state.skipSilence) {
                                        _player.action.setSilenceConfig(
                                          SilenceSkipConfig(
                                            mode: _silenceMode,
                                            thresholdDb: -45.0,
                                            minSilenceDuration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            padding: const Duration(
                                              milliseconds: 50,
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> points;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;

  WaveformPainter({
    required this.points,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= 0 || size.height <= 0) return;

    final barWidth = size.width / points.length;
    final spacing = (barWidth * 0.25).clamp(1.0, 3.0);
    final actualBarWidth = (barWidth - spacing).clamp(1.0, 16.0);
    final playedPaint = Paint()..color = playedColor;
    final unplayedPaint = Paint()..color = unplayedColor;

    for (int i = 0; i < points.length; i++) {
      final pointProgress = (i + 0.5) / points.length;
      final isPlayed = pointProgress <= progress;
      final paint = isPlayed ? playedPaint : unplayedPaint;

      final normalizedVal = points[i].clamp(0.05, 1.0);
      final minBarHeight = min(4.0, size.height);
      final barHeight =
          (size.height * normalizedVal).clamp(minBarHeight, size.height);
      final left = i * barWidth + (spacing / 2);
      final top = (size.height - barHeight) / 2;

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, actualBarWidth, barHeight),
        Radius.circular(actualBarWidth / 2),
      );
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.points != points ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.unplayedColor != unplayedColor;
  }
}
