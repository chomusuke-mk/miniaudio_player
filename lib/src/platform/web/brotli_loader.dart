import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// Helper utility resolving and loading miniaudio WebAssembly assets.
class BrotliWasmLoader {
  static const List<String> candidatePaths = [
    'assets/packages/miniaudio_player/assets/web/miniaudio_player.wasm.br',
    'assets/assets/web/miniaudio_player.wasm.br',
    'packages/miniaudio_player/assets/web/miniaudio_player.wasm.br',
    'assets/web/miniaudio_player.wasm.br',
    'assets/packages/miniaudio_player/assets/web/miniaudio_player.wasm',
    'assets/assets/web/miniaudio_player.wasm',
    'assets/web/miniaudio_player.wasm',
  ];

  /// Resolves the valid URL for the WebAssembly binary on the current host.
  static Future<String> resolveWasmUrl() async {
    for (final path in candidatePaths) {
      try {
        final absUrl = Uri.base.resolve(path).toString();
        final resp = await web.window.fetch(
          absUrl.toJS,
          web.RequestInit(method: 'HEAD'),
        ).toDart;
        if (resp.ok) {
          return absUrl;
        }
      } catch (_) {
        // Try next candidate path
      }
    }
    // Default fallback
    return Uri.base.resolve(candidatePaths[0]).toString();
  }
}
