import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/compact_slider_overlay.dart';
import '../../../shared/widgets/dsp_sub_card.dart';

/// Preset classification matching known Bauer BS2B configurations or custom
/// manual tuning.
enum _CrossfeedPreset {
  /// Standard Bauer BS2B reference curve (`700 Hz`, `4.5 dB`).
  moffatBauer,

  /// Chu Moy crossfeed reference curve (`700 Hz`, `6.0 dB`).
  chuMoy,

  /// User-adjusted cutoff or feed level outside built-in presets.
  custom,
}

/// Pure presentational sub-card panel for Bauer Stereophonic-to-Binaural (BS2B)
/// headphone crossfeed, rendering preset selection and cutoff/feed pills.
class CrossfeedPanel extends StatelessWidget {
  /// Current crossfeed configuration displayed by this panel.
  final Crossfeed crossfeed;

  /// Invoked when the user toggles the crossfeed power switch.
  final ValueChanged<bool> onToggle;

  /// Invoked with the selected preset [Crossfeed] configuration.
  final ValueChanged<Crossfeed> onPresetSelected;

  /// Invoked when the user adjusts the lowpass cutoff frequency in Hz.
  final ValueChanged<double> onCutoffChanged;

  /// Invoked when the user adjusts the crossfeed attenuation level in dB.
  final ValueChanged<double> onFeedChanged;

  /// Creates a [CrossfeedPanel] bound to [crossfeed] and [onToggle],
  /// [onPresetSelected], [onCutoffChanged], and [onFeedChanged] callbacks.
  const CrossfeedPanel({
    super.key,
    required this.crossfeed,
    required this.onToggle,
    required this.onPresetSelected,
    required this.onCutoffChanged,
    required this.onFeedChanged,
  });

  /// Detects which [_CrossfeedPreset] corresponds to [cf].
  _CrossfeedPreset _detectPreset(Crossfeed cf) {
    final cutoffRounded = cf.cutoffHz.round();
    final feedTenths = (cf.feedDb * 10).round();
    if (cutoffRounded == 700 && feedTenths == 45) {
      return _CrossfeedPreset.moffatBauer;
    }
    if (cutoffRounded == 700 && feedTenths == 60) {
      return _CrossfeedPreset.chuMoy;
    }
    return _CrossfeedPreset.custom;
  }

  /// Builds the labeled preset dropdown for [cf] showing [currentPreset].
  Widget _buildPresetDropdown(Crossfeed cf, _CrossfeedPreset currentPreset) {
    return DropdownButtonFormField<_CrossfeedPreset>(
      key: ValueKey(currentPreset),
      initialValue: currentPreset,
      isExpanded: true,
      dropdownColor: const Color(0xFF0E1424),
      decoration: const InputDecoration(
        labelText: 'Preset',
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      items: [
        const DropdownMenuItem(
          value: _CrossfeedPreset.moffatBauer,
          child: Text(
            'Moffat-Bauer',
            style: TextStyle(fontSize: 10.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const DropdownMenuItem(
          value: _CrossfeedPreset.chuMoy,
          child: Text(
            'Chu Moy',
            style: TextStyle(fontSize: 10.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DropdownMenuItem(
          value: _CrossfeedPreset.custom,
          enabled: currentPreset == _CrossfeedPreset.custom,
          child: Text(
            'Custom',
            style: TextStyle(
              fontSize: 10.5,
              fontStyle: FontStyle.italic,
              color: currentPreset == _CrossfeedPreset.custom
                  ? StudioColors.accentCyan
                  : StudioColors.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      onChanged: cf.enabled
          ? (preset) {
              if (preset == null || preset == _CrossfeedPreset.custom) return;
              final target = preset == _CrossfeedPreset.moffatBauer
                  ? Crossfeed.moffatBauer
                  : Crossfeed.chuMoy;
              onPresetSelected(target);
            }
          : null,
    );
  }

  /// Builds the BS2B crossfeed controls inside [DspSubCard].
  @override
  Widget build(BuildContext context) {
    final currentPreset = _detectPreset(crossfeed);

    return DspSubCard(
      icon: Icons.headphones,
      title: 'Bauer BS2B Crossfeed',
      subtitle: crossfeed.enabled
          ? 'Active: ${crossfeed.cutoffHz.round()}Hz • ${crossfeed.feedDb.toStringAsFixed(1)}dB crossfeed'
          : 'Reduces headphone fatigue via subtle inter-ear bleed',
      enabled: crossfeed.enabled,
      accentColor: StudioColors.accentCyan,
      onToggle: onToggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPresetDropdown(crossfeed, currentPreset),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              CompactSliderControl(
                icon: Icons.waves,
                label: 'Lowpass Cutoff: ${crossfeed.cutoffHz.round()} Hz',
                valueFormatter: (value) => '${value.round()} Hz',
                value: crossfeed.cutoffHz,
                defaultValue: Crossfeed.moffatBauer.cutoffHz,
                min: 300.0,
                max: 2000.0,
                activeColor: StudioColors.accentCyan,
                disabled: !crossfeed.enabled,
                onChanged: onCutoffChanged,
              ),
              CompactSliderControl(
                icon: Icons.compare_arrows,
                label:
                    'Crossfeed Level: ${crossfeed.feedDb.toStringAsFixed(1)} dB',
                valueFormatter: (value) => '${value.toStringAsFixed(1)} dB',
                value: crossfeed.feedDb,
                defaultValue: Crossfeed.moffatBauer.feedDb,
                min: 1.0,
                max: 15.0,
                activeColor: StudioColors.accentPurple,
                disabled: !crossfeed.enabled,
                onChanged: onFeedChanged,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// No-op [Crossfeed] preset callback safe for widget previews.
void _noopCrossfeedPreset(Crossfeed _) {}

/// Preview rendering [CrossfeedPanel] with the Moffat-Bauer preset enabled.
@StudioPreview(
  name: 'Bauer BS2B Crossfeed',
  group: 'DSP',
  size: Size(320, 240),
)
Widget crossfeedPanelPreview() {
  return CrossfeedPanel(
    crossfeed: Crossfeed.moffatBauer.copyWith(enabled: true),
    onToggle: StudioPreviewData.noopBool,
    onPresetSelected: _noopCrossfeedPreset,
    onCutoffChanged: StudioPreviewData.noopDouble,
    onFeedChanged: StudioPreviewData.noopDouble,
  );
}
