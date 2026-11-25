import 'package:material_ui/material_ui.dart';

import '../../../core/theme/studio_colors.dart';
import '../../console/controllers/audio_engine_controller.dart';
import 'sfx_pad_grid.dart';

/// Card showcasing native RAM sound effects and voice pool management in Rust.
class RamSoundEffectsCard extends StatelessWidget {
  /// Console controller exposing SFX streams and voice playback actions.
  final AudioEngineController controller;

  /// Creates a [RamSoundEffectsCard] bound to [controller].
  const RamSoundEffectsCard({super.key, required this.controller});

  /// Built-in synthesized RAM SFX trigger pad descriptors displayed by this card.
  static const List<SfxPadEntry> _sampleEffects = [
    SfxPadEntry(
      id: 'sfx_laser',
      name: 'Laser SFX (880Hz)',
      icon: Icons.flash_on,
      color: StudioColors.accentCyan,
    ),
    SfxPadEntry(
      id: 'sfx_chime',
      name: 'Chime SFX (1320Hz)',
      icon: Icons.notifications_active,
      color: StudioColors.accentPurple,
    ),
    SfxPadEntry(
      id: 'sfx_beep',
      name: 'Beep SFX (440Hz)',
      icon: Icons.radio_button_checked,
      color: StudioColors.accentEmerald,
    ),
  ];

  /// Maps [loadedIds] reported by the native engine into typed [SfxPadEntry] items.
  List<SfxPadEntry> _resolveLoadedEffects(List<String> loadedIds) {
    final loadedSet = loadedIds.toSet();
    final result = <SfxPadEntry>[
      for (final entry in _sampleEffects)
        if (loadedSet.contains(entry.id)) entry,
    ];
    final knownIds = {for (final entry in _sampleEffects) entry.id};
    for (final id in loadedIds) {
      if (!knownIds.contains(id)) {
        result.add(
          SfxPadEntry(
            id: id,
            name: id,
            icon: Icons.graphic_eq,
            color: StudioColors.accentCyan,
          ),
        );
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;

    return StreamBuilder<List<String>>(
      stream: engine.stream.loadedEffectIds,
      initialData: engine.state.loadedEffectIds,
      builder: (context, loadedSnap) {
        final loadedIds = loadedSnap.data ?? engine.state.loadedEffectIds;
        final effects = _resolveLoadedEffects(loadedIds);

        return StreamBuilder<int>(
          stream: engine.stream.allocatedRamBytes,
          initialData: engine.state.allocatedRamBytes,
          builder: (context, ramSnap) {
            final ramBytes = ramSnap.data ?? engine.state.allocatedRamBytes;

            return SfxPadPanel(
              effects: effects,
              allocatedRamBytes: ramBytes,
              onReload: controller.loadSampleEffects,
              onUnloadAll:
                  loadedIds.isNotEmpty ? controller.unloadAllEffects : null,
              onPlayEffect: (id) => controller.playSampleEffect(id),
            );
          },
        );
      },
    );
  }
}
