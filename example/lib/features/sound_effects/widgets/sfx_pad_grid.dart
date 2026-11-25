import 'package:material_ui/material_ui.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_card.dart';

/// Pure descriptor representing a single loaded RAM sound effect entry.
class SfxPadEntry {
  /// Identifier matching the native sound effect registered on the engine.
  final String id;

  /// Human-readable pad label displayed in the list item.
  final String name;

  /// Material icon rendered inside the pad avatar box.
  final IconData icon;

  /// Accent color applied to [icon].
  final Color color;

  /// Creates an [SfxPadEntry] with [id], [name], [icon], and [color].
  const SfxPadEntry({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
  });
}

/// Pure reusable sound-effect trigger pad grid displaying allocated RAM
/// telemetry, Reload/Unload controls, and playable [effects].
class SfxPadPanel extends StatelessWidget {
  /// Currently loaded sound effect entries displayed as clickable rows.
  final List<SfxPadEntry> effects;

  /// Native RAM bytes currently occupied by decoded SFX PCM buffers.
  final int allocatedRamBytes;

  /// Invoked when the user triggers Reload to populate sample effects.
  final VoidCallback onReload;

  /// Optional callback invoked when the user taps Unload All (disabled if `null`).
  final VoidCallback? onUnloadAll;

  /// Invoked when the user taps an effect pad to trigger playback of its `id`.
  final ValueChanged<String> onPlayEffect;

  /// Creates a pure [SfxPadPanel] displaying [effects], [allocatedRamBytes],
  /// [onReload], [onUnloadAll], and [onPlayEffect].
  const SfxPadPanel({
    super.key,
    required this.effects,
    required this.allocatedRamBytes,
    required this.onReload,
    required this.onUnloadAll,
    required this.onPlayEffect,
  });

  /// Builds a pill action button inside the RAM SFX control strip.
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

  /// Renders a clickable effect trigger tile for [effect].
  Widget _buildEffectListItem(SfxPadEntry effect) {
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
          onTap: () => onPlayEffect(effect.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ramKb = (allocatedRamBytes / 1024).toStringAsFixed(1);

    return StudioCard(
      icon: Icons.memory,
      title: 'NATIVE RAM SOUND EFFECTS & MEMORY',
      subtitle: 'Zero Dart RAM Duplication • Rust Decoded Voice Pool',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0F1D),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: StudioColors.cardBorder, width: 1.0),
            ),
            child: Wrap(
              alignment: WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                StudioBadge(
                  label: '$ramKb KB RAM',
                  color: allocatedRamBytes > 0
                      ? StudioColors.accentEmerald
                      : StudioColors.textMuted,
                ),
                _buildHeaderActionButton(
                  icon: Icons.refresh,
                  label: 'Reload',
                  tooltip: 'Reload sample RAM effects',
                  color: StudioColors.accentCyan,
                  onPressed: onReload,
                ),
                _buildHeaderActionButton(
                  icon: Icons.layers_clear_outlined,
                  label: 'Unload All',
                  tooltip: 'Unload All (0 KB)',
                  color: StudioColors.accentRose,
                  onPressed: onUnloadAll,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 210,
            decoration: BoxDecoration(
              color: const Color(0xFF070B14),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: StudioColors.cardBorder, width: 1.0),
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
  }
}

/// Constant no-op SFX play callback for widget previews.
void _noopPlaySfx(String _) {}

/// Preview displaying [SfxPadPanel] loaded with synthesized sample effects.
@StudioPreview(
  name: 'RAM Sound Effects Panel',
  group: 'Sound Effects',
  size: Size(360, 380),
)
Widget sfxPadPanelPreview() {
  return const SfxPadPanel(
    allocatedRamBytes: 68800,
    effects: [
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
    ],
    onReload: StudioPreviewData.noopVoid,
    onUnloadAll: StudioPreviewData.noopVoid,
    onPlayEffect: _noopPlaySfx,
  );
}
