import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/compact_slider_overlay.dart';
import '../common/dsp_sub_card.dart';
import '../common/studio_card.dart';

enum _CrossfeedPreset { moffatBauer, chuMoy, custom }

/// Sub-card module for Bauer Stereophonic-to-Binaural (BS2B) crossfeed,
/// designed to match Smart Silence Skipping inside [DspEffectsCard].
class BauerCrossfeedSubCard extends StatelessWidget {
  final AudioEngineController controller;

  const BauerCrossfeedSubCard({super.key, required this.controller});

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
              controller.setCrossfeed(
                cf.copyWith(cutoffHz: target.cutoffHz, feedDb: target.feedDb),
              );
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final cf = controller.crossfeed;
        final currentPreset = _detectPreset(cf);

        return DspSubCard(
          icon: Icons.headphones,
          title: 'Bauer BS2B Crossfeed',
          subtitle: cf.enabled
              ? 'Active: ${cf.cutoffHz.round()}Hz • ${cf.feedDb.toStringAsFixed(1)}dB crossfeed'
              : 'Reduces headphone fatigue via subtle inter-ear bleed',
          enabled: cf.enabled,
          accentColor: StudioColors.accentCyan,
          onToggle: controller.toggleCrossfeed,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPresetDropdown(cf, currentPreset),
              const SizedBox(height: 8),
              CompactSliderControl(
                icon: Icons.waves,
                label: 'Lowpass Cutoff: ${cf.cutoffHz.round()} Hz',
                value: cf.cutoffHz,
                defaultValue: Crossfeed.moffatBauer.cutoffHz,
                min: 300.0,
                max: 2000.0,
                activeColor: StudioColors.accentCyan,
                disabled: !cf.enabled,
                onChanged: controller.setCrossfeedCutoff,
              ),
              const SizedBox(height: 8),
              CompactSliderControl(
                icon: Icons.compare_arrows,
                label: 'Crossfeed Level: ${cf.feedDb.toStringAsFixed(1)} dB',
                value: cf.feedDb,
                defaultValue: Crossfeed.moffatBauer.feedDb,
                min: 1.0,
                max: 15.0,
                activeColor: StudioColors.accentPurple,
                disabled: !cf.enabled,
                onChanged: controller.setCrossfeedFeed,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Standalone Bauer BS2B card wrapper kept for backwards compatibility;
/// the active studio console mounts [BauerCrossfeedSubCard] inside [DspEffectsCard].
class CrossfeedCard extends StatelessWidget {
  final AudioEngineController controller;

  const CrossfeedCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return StudioCard(
      icon: Icons.headphones,
      title: 'BAUER BS2B CROSSFEED',
      child: BauerCrossfeedSubCard(controller: controller),
    );
  }
}
