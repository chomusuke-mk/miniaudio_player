import 'package:material_ui/material_ui.dart';

import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_card.dart';
import '../../console/controllers/audio_engine_controller.dart';
import 'crossfeed_sub_card.dart';
import 'equalizer_sub_card.dart';
import 'master_bus_controls.dart';
import 'reverb_sub_card.dart';
import 'silence_skip_panel.dart';
import 'stereo_widener_panel.dart';

/// Card hosting live DSP and spatial mastering processors backed by
/// [AudioEngineController]:
/// - ReplayGain master normalization
/// - True-Peak brickwall limiter
/// - Monophonic downmixing
/// - Master preamplifier gain and stereo pan balance
/// - Pause-on-device-change protection and live metadata event streaming
/// - Intelligent silence skipping
/// - Bauer BS2B binaural crossfeed
/// - Mid/Side stereo widener
/// - Algorithmic Freeverb reverberation
/// - ISO 266 10-band parametric equalizer
class DspEffectsCard extends StatelessWidget {
  /// Controller providing DSP state streams and real-time parameter RPCs.
  final AudioEngineController controller;

  /// Creates a [DspEffectsCard] bound to [controller].
  const DspEffectsCard({super.key, required this.controller});

  /// Builds the controller-bound smart silence skipping sub-card.
  Widget _buildSmartSilenceSubCard() {
    return ListenableBuilder(
      listenable: controller.silenceListenable,
      builder: (context, _) {
        return SilenceSkipPanel(
          enabled: controller.silenceEnabled,
          mode: controller.silenceMode,
          thresholdDb: controller.silenceThresholdDb,
          savedDuration: controller.silenceSavedDuration,
          onToggle: controller.setSilenceSkipEnabled,
          onModeChanged: controller.setSilenceMode,
          onThresholdChanged: controller.setSilenceThresholdDb,
        );
      },
    );
  }

  /// Builds the controller-bound Mid/Side stereo widener sub-card.
  Widget _buildStereoWidenerSubCard() {
    return ListenableBuilder(
      listenable: controller.spatializerListenable,
      builder: (context, _) {
        return StereoWidenerPanel(
          enabled: controller.spatializerEnabled,
          width: controller.spatializerWidth,
          onToggle: controller.setSpatializerEnabled,
          onWidthChanged: controller.setSpatializerWidth,
        );
      },
    );
  }

  /// Lays out the silence skipper, crossfeed, stereo widener, reverb, and
  /// equalizer sub-cards across responsive width tiers (`<420`, `620..779`,
  /// and `>=780` logical pixels) inside [maxWidth].
  Widget _buildSubCardMasteringSection(double maxWidth) {
    const spacing = 10.0;
    final silence = _buildSmartSilenceSubCard();
    final crossfeed = BauerCrossfeedSubCard(controller: controller);
    final widener = _buildStereoWidenerSubCard();
    final reverb = ReverbSubCard(controller: controller);
    final equalizer = EqualizerSubCard(controller: controller);

    if (maxWidth < 420) {
      return MasterBusControls.buildResponsiveGrid(
        [silence, crossfeed, widener, reverb, equalizer],
        maxWidth,
        spacing: spacing,
      );
    }

    final isThreeColDrop = maxWidth >= 620 && maxWidth < 780;
    final topGridCards = isThreeColDrop
        ? [silence, crossfeed, widener]
        : [silence, crossfeed, widener, reverb];
    final bottomSection = isThreeColDrop
        ? IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: (maxWidth - spacing * 2) / 3,
                  child: reverb,
                ),
                const SizedBox(width: spacing),
                Expanded(child: equalizer),
              ],
            ),
          )
        : equalizer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MasterBusControls.buildResponsiveGrid(
          topGridCards,
          maxWidth,
          spacing: spacing,
        ),
        const SizedBox(height: spacing),
        bottomSection,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final masterBusListenable = Listenable.merge([
      controller.replayGainListenable,
      controller.limiterListenable,
      controller.monoListenable,
      controller.preampListenable,
      controller.balanceListenable,
      controller.pauseOnDeviceChangeListenable,
      controller.metadataEnabledListenable,
    ]);

    return StudioCard(
      icon: Icons.tune,
      title: 'DYNAMIC DSP & SPATIAL MASTERING',
      subtitle:
          'True-Peak Limiter • Silence Skipper • BS2B Crossfeed • Stereo Widener • Freeverb Reverb • Preamp • ReplayGain',
      trailing: const StudioBadge(
        label: 'Mastering Chain',
        color: StudioColors.accentCyan,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: masterBusListenable,
            builder: (context, _) {
              return MasterBusControls(
                replayGainMode: controller.replayGainMode,
                onReplayGainModeChanged: controller.setReplayGainMode,
                limiterEnabled: controller.limiterEnabled,
                onLimiterChanged: controller.setLimiterEnabled,
                monoDownmix: controller.monoDownmix,
                onMonoDownmixChanged: controller.setMonoDownmix,
                preampDb: controller.preampDb,
                onPreampChanged: controller.setPreamp,
                stereoBalance: controller.stereoBalance,
                onStereoBalanceChanged: controller.setStereoBalance,
                pauseOnDeviceChange: controller.pauseOnDeviceChange,
                onPauseOnDeviceChangeChanged: controller.setPauseOnDeviceChange,
                metadataEnabled: controller.metadataEnabled,
                onMetadataEnabledChanged: controller.setMetadataEnabled,
              );
            },
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              return _buildSubCardMasteringSection(constraints.maxWidth);
            },
          ),
        ],
      ),
    );
  }
}
