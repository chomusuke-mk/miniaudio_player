import 'package:flutter/material.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

class _EffectEntry {
  final String id;
  final String name;
  final IconData icon;
  final Color color;

  const _EffectEntry({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
  });
}

/// Card showcasing native RAM sound effects and voice pool management in Rust.
/// Shares the queue card layout with a top action wrap row and clean effect list.
class RamSoundEffectsCard extends StatelessWidget {
  final AudioEngineController controller;

  const RamSoundEffectsCard({super.key, required this.controller});

  static const List<_EffectEntry> _sampleEffects = [
    _EffectEntry(
      id: 'sfx_laser',
      name: 'Laser SFX (880Hz)',
      icon: Icons.flash_on,
      color: StudioColors.accentCyan,
    ),
    _EffectEntry(
      id: 'sfx_chime',
      name: 'Chime SFX (1320Hz)',
      icon: Icons.notifications_active,
      color: StudioColors.accentPurple,
    ),
    _EffectEntry(
      id: 'sfx_beep',
      name: 'Beep SFX (440Hz)',
      icon: Icons.radio_button_checked,
      color: StudioColors.accentEmerald,
    ),
  ];

  List<_EffectEntry> _resolveLoadedEffects(List<String> loadedIds) {
    final loadedSet = loadedIds.toSet();
    final result = <_EffectEntry>[
      for (final entry in _sampleEffects)
        if (loadedSet.contains(entry.id)) entry,
    ];
    final knownIds = {for (final entry in _sampleEffects) entry.id};
    for (final id in loadedIds) {
      if (!knownIds.contains(id)) {
        result.add(
          _EffectEntry(
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

  Widget _buildHeaderActionButton({
    required IconData icon,
    required String label,
    required String tooltip,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    final isEnabled = onPressed != null;
    final foregroundColor = isEnabled ? color : StudioColors.textMuted;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: StudioColors.backgroundDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(
            color: isEnabled
                ? color.withValues(alpha: 0.65)
                : StudioColors.cardBorder,
            width: 1.0,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12.5, color: foregroundColor),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: foregroundColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEffectListItem(_EffectEntry effect) {
    return Padding(
      key: ValueKey('sfx_${effect.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: const Color(0xFF0C1222),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: StudioColors.cardBorder, width: 0.8),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 2,
          ),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFF080D1A),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: StudioColors.cardBorder, width: 0.8),
            ),
            child: Icon(effect.icon, size: 16, color: effect.color),
          ),
          title: Text(
            effect.name,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => controller.playSampleEffect(effect.id),
        ),
      ),
    );
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
            final ramKb = (ramBytes / 1024).toStringAsFixed(1);

            return StudioCard(
              icon: Icons.memory,
              title: 'NATIVE RAM SOUND EFFECTS & MEMORY',
              subtitle: 'Zero Dart RAM Duplication • Rust Decoded Voice Pool',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // RAM Badge + Reload / Unload All controls in one left-aligned Wrap row
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0F1D),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: StudioColors.cardBorder,
                        width: 1.0,
                      ),
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.start,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        StudioBadge(
                          label: '$ramKb KB RAM',
                          color: ramBytes > 0
                              ? StudioColors.accentEmerald
                              : StudioColors.textMuted,
                        ),
                        _buildHeaderActionButton(
                          icon: Icons.refresh,
                          label: 'Reload',
                          tooltip: 'Reload sample RAM effects',
                          color: StudioColors.accentCyan,
                          onPressed: controller.loadSampleEffects,
                        ),
                        _buildHeaderActionButton(
                          icon: Icons.layers_clear_outlined,
                          label: 'Unload All',
                          tooltip: 'Unload All (0 KB)',
                          color: StudioColors.accentRose,
                          onPressed: loadedIds.isNotEmpty
                              ? controller.unloadAllEffects
                              : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Scrollable Sound Effects List matching Queue design (icon + name only)
                  Container(
                    height: 210,
                    decoration: BoxDecoration(
                      color: const Color(0xFF070B14),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: StudioColors.cardBorder,
                        width: 1.0,
                      ),
                    ),
                    child: effects.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                'No effects loaded in RAM. Tap Reload to load sample effects',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: StudioColors.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: effects.length,
                            itemBuilder: (context, index) =>
                                _buildEffectListItem(effects[index]),
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
