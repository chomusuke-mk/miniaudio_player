import 'dart:js_interop';
import 'package:web/web.dart' as web;
import '../../api/miniaudio_player.dart';

/// Helper utility resolving and loading miniaudio WebAssembly assets.
class WasmLoader {
  static const List<String> candidatePaths = [
    'assets/packages/miniaudio_player/assets/miniaudio_player.wasm',
    'packages/miniaudio_player/assets/miniaudio_player.wasm',
    'assets/assets/miniaudio_player.wasm',
    'assets/miniaudio_player.wasm',
    'miniaudio_player.wasm',
  ];

  /// Resolves the valid URL for the WebAssembly binary on the current host.
  static Future<String> resolveWasmUrl() async {
    // 1. If global assetLoader is registered, load bytes directly and return a Blob URL
    final loader = MiniaudioPlayerGlobalConfig.assetLoader;
    if (loader != null) {
      try {
        final bytes = await loader(
          'packages/miniaudio_player/assets/miniaudio_player.wasm',
        );
        if (bytes.isNotEmpty) {
          final blob = web.Blob(
            [bytes.toJS].toJS,
            web.BlobPropertyBag(type: 'application/wasm'),
          );
          return web.URL.createObjectURL(blob);
        }
      } catch (_) {}
    }

    // 2. Probe candidate paths via fetch
    final baseStr = web.document.baseURI.isNotEmpty
        ? web.document.baseURI
        : Uri.base.toString();
    final baseUri = Uri.parse(baseStr);

    for (final path in candidatePaths) {
      try {
        final absUrl = baseUri.resolve(path).toString();
        final resp = await web.window
            .fetch(
              absUrl.toJS,
              web.RequestInit(method: 'HEAD'),
            )
            .toDart;
        if (resp.ok) {
          return absUrl;
        }
      } catch (_) {
        // Try next candidate path
      }
    }

    // 3. Fallback default
    return baseUri.resolve(candidatePaths[0]).toString();
  }
}
