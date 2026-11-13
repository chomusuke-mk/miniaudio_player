import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

/// Card managing multi-endpoint playback output devices and multi-capture input sources.
class HardwareRoutingCard extends StatelessWidget {
  final AudioEngineController controller;

  const HardwareRoutingCard({super.key, required this.controller});

  void _openInputConfigDialog(BuildContext context, AudioDevice device) {
    final curConfig = controller.getInputConfig(device.id);

    double volume = curConfig.volume;
    bool monitorDirect = curConfig.monitorDirect;
    double monitorVolume = curConfig.monitorVolume;
    bool duckingEnabled = curConfig.ducking?.enabled ?? false;
    double duckingDb = curConfig.ducking?.duckingDb ?? -14.0;
    double thresholdDb = curConfig.ducking?.thresholdDb ?? -30.0;
    double attackMs = curConfig.ducking?.attackMs ?? 30.0;
    double holdMs = curConfig.ducking?.holdMs ?? 250.0;
    double releaseMs = curConfig.ducking?.releaseMs ?? 400.0;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(
                  color: StudioColors.cardBorder,
                  width: 1.2,
                ),
              ),
              title: Row(
                children: [
                  const Icon(
                    Icons.settings,
                    color: StudioColors.accentCyan,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Configure ${device.displayName}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Volume Slider
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Capture Volume',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            '${(volume * 100).round()}%',
                            style: const TextStyle(
                              fontSize: 12,
                              color: StudioColors.accentCyan,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: volume,
                        min: 0.0,
                        max: 2.0,
                        activeColor: StudioColors.accentCyan,
                        onChanged: (v) => setDialogState(() => volume = v),
                      ),
                      const Divider(color: StudioColors.cardBorder),

                      // Direct Monitoring Switch
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Direct Monitoring',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        subtitle: const Text(
                          'Pass-through input directly to master output mix',
                          style: TextStyle(
                            fontSize: 10,
                            color: StudioColors.textMuted,
                          ),
                        ),
                        value: monitorDirect,
                        activeThumbColor: StudioColors.accentEmerald,
                        onChanged: (v) =>
                            setDialogState(() => monitorDirect = v),
                      ),
                      if (monitorDirect) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Monitor Volume',
                              style: TextStyle(
                                fontSize: 11,
                                color: StudioColors.textSecondary,
                              ),
                            ),
                            Text(
                              '${(monitorVolume * 100).round()}%',
                              style: const TextStyle(
                                fontSize: 11,
                                color: StudioColors.accentEmerald,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: monitorVolume,
                          min: 0.0,
                          max: 2.0,
                          activeColor: StudioColors.accentEmerald,
                          onChanged: (v) =>
                              setDialogState(() => monitorVolume = v),
                        ),
                      ],
                      const Divider(color: StudioColors.cardBorder),

                      // Auto-Ducking Section
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Microphone Auto-Ducking',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        subtitle: const Text(
                          'Sidechain attenuates music bus during speech',
                          style: TextStyle(
                            fontSize: 10,
                            color: StudioColors.textMuted,
                          ),
                        ),
                        value: duckingEnabled,
                        activeThumbColor: StudioColors.accentAmber,
                        onChanged: (v) =>
                            setDialogState(() => duckingEnabled = v),
                      ),
                      if (duckingEnabled) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Ducking Attenuation',
                              style: TextStyle(
                                fontSize: 11,
                                color: StudioColors.textSecondary,
                              ),
                            ),
                            Text(
                              '${duckingDb.toStringAsFixed(1)} dB',
                              style: const TextStyle(
                                fontSize: 11,
                                color: StudioColors.accentAmber,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: duckingDb,
                          min: -40.0,
                          max: 0.0,
                          activeColor: StudioColors.accentAmber,
                          onChanged: (v) => setDialogState(() => duckingDb = v),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Trigger Threshold',
                              style: TextStyle(
                                fontSize: 11,
                                color: StudioColors.textSecondary,
                              ),
                            ),
                            Text(
                              '${thresholdDb.toStringAsFixed(1)} dB',
                              style: const TextStyle(
                                fontSize: 11,
                                color: StudioColors.accentAmber,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: thresholdDb,
                          min: -60.0,
                          max: -10.0,
                          activeColor: StudioColors.accentAmber,
                          onChanged: (v) =>
                              setDialogState(() => thresholdDb = v),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Attack / Hold / Release (ms)',
                              style: TextStyle(
                                fontSize: 10,
                                color: StudioColors.textMuted,
                              ),
                            ),
                            Text(
                              '${attackMs.round()} / ${holdMs.round()} / ${releaseMs.round()} ms',
                              style: const TextStyle(
                                fontSize: 10,
                                color: StudioColors.accentAmber,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: StudioColors.textMuted),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: StudioColors.accentCyan,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text(
                    'Apply',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onPressed: () async {
                    final config = AudioInputConfig(
                      volume: volume,
                      monitorDirect: monitorDirect,
                      monitorVolume: monitorVolume,
                      ducking: duckingEnabled
                          ? DuckingConfig(
                              enabled: true,
                              duckingDb: duckingDb,
                              thresholdDb: thresholdDb,
                              attackMs: attackMs,
                              holdMs: holdMs,
                              releaseMs: releaseMs,
                            )
                          : null,
                    );
                    await controller.configureInputDevice(device.id, config);
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<AudioDevice>>(
      stream: controller.engine.stream.globalOutputDevices,
      initialData: controller.engine.state.globalOutputDevices,
      builder: (context, outDevsSnap) {
        final outDevs =
            outDevsSnap.data ?? controller.engine.state.globalOutputDevices;

        return StreamBuilder<List<AudioDevice>>(
          stream: controller.engine.stream.globalInputDevices,
          initialData: controller.engine.state.globalInputDevices,
          builder: (context, inDevsSnap) {
            final inDevs =
                inDevsSnap.data ?? controller.engine.state.globalInputDevices;

            return StreamBuilder<Set<AudioOutput>>(
              stream: controller.engine.stream.outputs,
              initialData: controller.engine.state.outputs,
              builder: (context, outputsSnap) {
                final outputs =
                    outputsSnap.data ?? controller.engine.state.outputs;

                return StreamBuilder<Set<AudioInput>>(
                  stream: controller.engine.stream.inputs,
                  initialData: controller.engine.state.inputs,
                  builder: (context, inputsSnap) {
                    final inputs =
                        inputsSnap.data ?? controller.engine.state.inputs;

                    return ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) {
                        return StudioCard(
                          icon: Icons.alt_route,
                          title: 'AUDIO HARDWARE ROUTING MATRIX',
                          subtitle: 'Multi-Destination Output Matrix • Multi-Capture Microphones with Auto-Ducking',
                          trailing: Wrap(
                            spacing: 6,
                            children: [
                              StudioBadge(
                                label: '${outputs.length} OUT',
                                color: outputs.isNotEmpty
                                    ? StudioColors.accentCyan
                                    : StudioColors.textMuted,
                              ),
                              StudioBadge(
                                label: '${inputs.length} IN',
                                color: inputs.isNotEmpty
                                    ? StudioColors.accentAmber
                                    : StudioColors.textMuted,
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // =============================================================
                              // Section 1: Output Devices List (Default: AUTO selected)
                              // =============================================================
                              Row(
                                children: const [
                                  Icon(
                                    Icons.headphones,
                                    size: 14,
                                    color: StudioColors.accentCyan,
                                  ),
                                  SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'PLAYBACK OUTPUT DESTINATIONS (MULTI-SELECT)',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: StudioColors.accentCyan,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF070B14),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: StudioColors.cardBorder,
                                  ),
                                ),
                                child: outDevs.isEmpty
                                    ? const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: Center(
                                          child: Text(
                                            'No playback destination hardware endpoints detected',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: StudioColors.textMuted,
                                            ),
                                          ),
                                        ),
                                      )
                                    : ListView.separated(
                                        shrinkWrap: true,
                                        physics:
                                            const NeverScrollableScrollPhysics(),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 2,
                                        ),
                                        itemCount: outDevs.length,
                                        separatorBuilder: (_, _) =>
                                            const Divider(
                                              height: 1,
                                              color: StudioColors.cardBorder,
                                            ),
                                        itemBuilder: (context, index) {
                                          final dev = outDevs[index];
                                          final isSelected = outputs.any(
                                            (o) => o.deviceId == dev.id,
                                          );
                                          final matchingOutput = isSelected
                                              ? outputs.firstWhere(
                                                  (o) => o.deviceId == dev.id,
                                                )
                                              : null;

                                          return Material(
                                            color: Colors.transparent,
                                            child: ListTile(
                                              dense: true,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 0,
                                                  ),
                                              leading: Checkbox(
                                                value: isSelected,
                                                activeColor:
                                                    StudioColors.accentCyan,
                                                checkColor: Colors.black,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                onChanged: (_) => controller
                                                    .toggleOutput(dev),
                                              ),
                                              title: Text(
                                                dev.displayName,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: isSelected
                                                      ? FontWeight.bold
                                                      : FontWeight.w500,
                                                  color: isSelected
                                                      ? Colors.white
                                                      : StudioColors
                                                            .textSecondary,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              subtitle: dev.isAuto
                                                  ? Text(
                                                      dev.resolvedName !=
                                                                  null &&
                                                              dev
                                                                  .resolvedName!
                                                                  .isNotEmpty
                                                          ? 'Auto-routes to: ${dev.resolvedName}'
                                                          : 'Auto-routes to active OS default audio endpoint',
                                                      style: const TextStyle(
                                                        fontSize: 9,
                                                        color: StudioColors
                                                            .accentCyan,
                                                      ),
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    )
                                                  : Text(
                                                      'Hardware ID: ${dev.id.substring(0, dev.id.length > 18 ? 18 : dev.id.length)}...',
                                                      style: const TextStyle(
                                                        fontSize: 9,
                                                        color: StudioColors
                                                            .textMuted,
                                                      ),
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                              trailing: isSelected
                                                  ? SizedBox(
                                                      width: 96,
                                                      child: Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 4,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: const Color(
                                                            0xFF0F172A,
                                                          ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                4,
                                                              ),
                                                          border: Border.all(
                                                            color: StudioColors
                                                                .cardBorder,
                                                          ),
                                                        ),
                                                        child: DropdownButtonHideUnderline(
                                                          child: DropdownButton<AudioOutputSource>(
                                                            value:
                                                                matchingOutput
                                                                    ?.source ??
                                                                AudioOutputSource
                                                                    .all,
                                                            icon: const Icon(
                                                              Icons
                                                                  .arrow_drop_down,
                                                              size: 14,
                                                            ),
                                                            dropdownColor:
                                                                const Color(
                                                                  0xFF0F172A,
                                                                ),
                                                            isExpanded: true,
                                                            isDense: true,
                                                            items: const [
                                                              DropdownMenuItem(
                                                                value:
                                                                    AudioOutputSource
                                                                        .all,
                                                                child: Text(
                                                                  'All Mix',
                                                                  style:
                                                                      TextStyle(
                                                                        fontSize:
                                                                            9.5,
                                                                      ),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                ),
                                                              ),
                                                              DropdownMenuItem(
                                                                value:
                                                                    AudioOutputSource
                                                                        .musicMix,
                                                                child: Text(
                                                                  'Music Only',
                                                                  style:
                                                                      TextStyle(
                                                                        fontSize:
                                                                            9.5,
                                                                      ),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                ),
                                                              ),
                                                              DropdownMenuItem(
                                                                value: AudioOutputSource
                                                                    .activeTrack,
                                                                child: Text(
                                                                  'Active Deck',
                                                                  style:
                                                                      TextStyle(
                                                                        fontSize:
                                                                            9.5,
                                                                      ),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                ),
                                                              ),
                                                              DropdownMenuItem(
                                                                value: AudioOutputSource
                                                                    .standbyTrack,
                                                                child: Text(
                                                                  'Cue Deck',
                                                                  style:
                                                                      TextStyle(
                                                                        fontSize:
                                                                            9.5,
                                                                      ),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                ),
                                                              ),
                                                              DropdownMenuItem(
                                                                value: AudioOutputSource
                                                                    .voiceOnly,
                                                                child: Text(
                                                                  'Voice Only',
                                                                  style:
                                                                      TextStyle(
                                                                        fontSize:
                                                                            9.5,
                                                                      ),
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                ),
                                                              ),
                                                            ],
                                                            onChanged: (src) {
                                                              if (src != null) {
                                                                controller
                                                                    .setOutputSource(
                                                                      dev.id,
                                                                      src,
                                                                    );
                                                              }
                                                            },
                                                          ),
                                                        ),
                                                      ),
                                                    )
                                                  : null,
                                              onTap: () =>
                                                  controller.toggleOutput(dev),
                                            ),
                                          );
                                        },
                                      ),
                              ),

                              const SizedBox(height: 12),

                              // =============================================================
                              // Section 2: Input Capture Devices List (Default: NONE selected, Gear icon)
                              // =============================================================
                              Row(
                                children: [
                                  const Icon(
                                    Icons.mic,
                                    size: 14,
                                    color: StudioColors.accentAmber,
                                  ),
                                  const SizedBox(width: 6),
                                  const Expanded(
                                    child: Text(
                                      'CAPTURE INPUT SOURCES (MULTI-SELECT)',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: StudioColors.accentAmber,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (controller
                                      .engine
                                      .state
                                      .isDuckingActive) ...[
                                    const SizedBox(width: 4),
                                    const StudioBadge(
                                      label: 'DUCKING ACTIVE',
                                      color: StudioColors.accentAmber,
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF070B14),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: StudioColors.cardBorder,
                                  ),
                                ),
                                child: inDevs.isEmpty
                                    ? const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: Center(
                                          child: Text(
                                            'No microphone capture hardware endpoints detected',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: StudioColors.textMuted,
                                            ),
                                          ),
                                        ),
                                      )
                                    : ListView.separated(
                                        shrinkWrap: true,
                                        physics:
                                            const NeverScrollableScrollPhysics(),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 2,
                                        ),
                                        itemCount: inDevs.length,
                                        separatorBuilder: (_, _) =>
                                            const Divider(
                                              height: 1,
                                              color: StudioColors.cardBorder,
                                            ),
                                        itemBuilder: (context, index) {
                                          final dev = inDevs[index];
                                          final isSelected = inputs.any(
                                            (i) => i.deviceId == dev.id,
                                          );

                                          return Material(
                                            color: Colors.transparent,
                                            child: ListTile(
                                              dense: true,
                                              visualDensity:
                                                  VisualDensity.compact,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 0,
                                                  ),
                                              leading: Checkbox(
                                                value: isSelected,
                                                activeColor:
                                                    StudioColors.accentAmber,
                                                checkColor: Colors.black,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                onChanged: (_) =>
                                                    controller.toggleInput(dev),
                                              ),
                                              title: Text(
                                                dev.displayName,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: isSelected
                                                      ? FontWeight.bold
                                                      : FontWeight.w500,
                                                  color: isSelected
                                                      ? Colors.white
                                                      : StudioColors
                                                            .textSecondary,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              subtitle: isSelected
                                                  ? StreamBuilder<double>(
                                                      stream: controller
                                                          .engine
                                                          .stream
                                                          .micRmsLevel,
                                                      initialData: controller
                                                          .engine
                                                          .state
                                                          .micRmsLevel,
                                                      builder: (context, rmsSnap) {
                                                        final rms =
                                                            rmsSnap.data ??
                                                            -100.0;
                                                        return Text(
                                                          'Active Capture • Level: ${rms.toStringAsFixed(1)} dBFS',
                                                          style: const TextStyle(
                                                            fontSize: 9,
                                                            color: StudioColors
                                                                .accentAmber,
                                                            fontFamily:
                                                                'monospace',
                                                          ),
                                                        );
                                                      },
                                                    )
                                                  : (dev.isAuto
                                                        ? Text(
                                                            dev.resolvedName !=
                                                                        null &&
                                                                    dev
                                                                        .resolvedName!
                                                                        .isNotEmpty
                                                                ? 'Auto-routes to: ${dev.resolvedName}'
                                                                : 'Auto-routes to default microphone',
                                                            style: const TextStyle(
                                                              fontSize: 9,
                                                              color: StudioColors
                                                                  .accentAmber,
                                                            ),
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          )
                                                        : Text(
                                                            'Hardware ID: ${dev.id.substring(0, dev.id.length > 18 ? 18 : dev.id.length)}...',
                                                            style: const TextStyle(
                                                              fontSize: 9,
                                                              color: StudioColors
                                                                  .textMuted,
                                                            ),
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          )),
                                              trailing: IconButton(
                                                icon: const Icon(
                                                  Icons.settings,
                                                  size: 16,
                                                ),
                                                color: isSelected
                                                    ? StudioColors.accentCyan
                                                    : StudioColors.textMuted,
                                                tooltip:
                                                    'Configure ${dev.displayName}',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                onPressed: () =>
                                                    _openInputConfigDialog(
                                                      context,
                                                      dev,
                                                    ),
                                              ),
                                              onTap: () =>
                                                  controller.toggleInput(dev),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ],
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
    );
  }
}
