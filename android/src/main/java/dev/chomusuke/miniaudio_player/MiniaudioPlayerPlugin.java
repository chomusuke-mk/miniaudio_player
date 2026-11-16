package dev.chomusuke.miniaudio_player;

import android.content.ContentResolver;
import android.content.Context;
import android.content.pm.PackageManager;
import android.content.res.AssetFileDescriptor;
import android.content.res.Resources;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.util.TypedValue;
import android.webkit.MimeTypeMap;

import androidx.annotation.NonNull;

import java.io.ByteArrayOutputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Lightweight Android MethodChannel micro-plugin resolving {@code content://}
 * (SAF / MediaStore) and {@code android.resource://} URIs into zero-copy
 * POSIX file descriptors ({@link ParcelFileDescriptor#detachFd()}) or fallback
 * compressed raw resource bytes for Rust's streaming audio engine.
 */
public final class MiniaudioPlayerPlugin implements FlutterPlugin, MethodCallHandler {
    private static final String CHANNEL_NAME = "dev.chomusuke.miniaudio_player/source_resolver";

    private Context applicationContext;
    private MethodChannel channel;
    private ExecutorService executor;
    private Handler mainHandler;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        applicationContext = binding.getApplicationContext();
        mainHandler = new Handler(Looper.getMainLooper());
        executor = Executors.newCachedThreadPool();
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
        if (executor != null) {
            executor.shutdown();
            executor = null;
        }
        applicationContext = null;
        mainHandler = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        final Context ctx = applicationContext;
        final ExecutorService exec = executor;
        if (ctx == null || exec == null) {
            result.error("UNAVAILABLE", "MiniaudioPlayerPlugin is detached from Android engine.", null);
            return;
        }

        final String uriArg = call.argument("uri");
        if (uriArg == null || uriArg.trim().isEmpty()) {
            result.error("INVALID_ARGS", "Missing non-empty 'uri' argument.", null);
            return;
        }

        switch (call.method) {
            case "openContentFd":
                exec.execute(() -> resolveContentUri(ctx, uriArg.trim(), result));
                break;
            case "openAndroidResource":
                exec.execute(() -> resolveAndroidResourceUri(ctx, uriArg.trim(), result));
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    private void postSuccess(@NonNull Result result, @NonNull Map<String, Object> payload) {
        final Handler handler = mainHandler;
        if (handler != null) {
            handler.post(() -> result.success(payload));
        }
    }

    private void postError(
            @NonNull Result result,
            @NonNull String code,
            @NonNull String message) {
        final Handler handler = mainHandler;
        if (handler != null) {
            handler.post(() -> result.error(code, message, null));
        }
    }

    private void resolveContentUri(
            @NonNull Context ctx,
            @NonNull String rawUri,
            @NonNull Result result) {
        final Uri uri;
        try {
            uri = Uri.parse(rawUri);
        } catch (Exception e) {
            postError(result, "INVALID_URI", "Malformed content URI '" + rawUri + "': " + e.getMessage());
            return;
        }

        final ContentResolver resolver = ctx.getContentResolver();
        final String hintExt = extractExtensionFromMime(resolver.getType(uri));

        try (AssetFileDescriptor afd = resolver.openAssetFileDescriptor(uri, "r")) {
            if (afd == null) {
                postError(result, "FILE_NOT_FOUND", "Content provider returned null descriptor for '" + rawUri + "'.");
                return;
            }

            final ParcelFileDescriptor pfd = afd.getParcelFileDescriptor();
            if (pfd != null) {
                final long startOffset = Math.max(0L, afd.getStartOffset());
                long length = afd.getDeclaredLength();
                if (length < 0L) {
                    final long statSize = pfd.getStatSize();
                    if (statSize >= 0L) {
                        length = statSize;
                    }
                }
                final int detachedFd = pfd.detachFd();
                final Map<String, Object> out = new HashMap<>();
                out.put("kind", "fd");
                out.put("fd", detachedFd);
                out.put("offset", startOffset);
                if (length >= 0L) {
                    out.put("length", length);
                }
                if (hintExt != null) {
                    out.put("hintExt", hintExt);
                }
                postSuccess(result, out);
                return;
            }

            // Virtual/streamed ContentProvider without an underlying FD: read stream bytes.
            try (InputStream is = afd.createInputStream()) {
                final byte[] bytes = readAllBytes(is);
                final Map<String, Object> out = new HashMap<>();
                out.put("kind", "bytes");
                out.put("bytes", bytes);
                if (hintExt != null) {
                    out.put("hintExt", hintExt);
                }
                postSuccess(result, out);
            }
        } catch (SecurityException e) {
            postError(
                    result,
                    "ACCESS_DENIED",
                    "Permission denied opening Android content URI '" + rawUri + "': " + e.getMessage());
        } catch (FileNotFoundException e) {
            postError(
                    result,
                    "FILE_NOT_FOUND",
                    "Android content URI not found '" + rawUri + "': " + e.getMessage());
        } catch (IllegalArgumentException e) {
            postError(
                    result,
                    "INVALID_URI",
                    "Invalid Android content URI '" + rawUri + "': " + e.getMessage());
        } catch (IOException e) {
            postError(
                    result,
                    "FILE_NOT_FOUND",
                    "I/O failure opening Android content URI '" + rawUri + "': " + e.getMessage());
        }
    }

    private void resolveAndroidResourceUri(
            @NonNull Context ctx,
            @NonNull String rawUri,
            @NonNull Result result) {
        final Uri uri;
        try {
            uri = Uri.parse(rawUri);
        } catch (Exception e) {
            postError(result, "INVALID_URI", "Malformed android.resource URI '" + rawUri + "': " + e.getMessage());
            return;
        }

        final String hostPkg = uri.getHost();
        final String packageName = (hostPkg == null || hostPkg.isEmpty()) ? ctx.getPackageName() : hostPkg;
        final List<String> segments = uri.getPathSegments();

        final Resources resources;
        try {
            resources = packageName.equals(ctx.getPackageName())
                    ? ctx.getResources()
                    : ctx.getPackageManager().getResourcesForApplication(packageName);
        } catch (PackageManager.NameNotFoundException e) {
            postError(
                    result,
                    "RESOURCE_NOT_FOUND",
                    "Package '" + packageName + "' not found for URI '" + rawUri + "'.");
            return;
        }

        int resId = 0;
        if (segments.size() == 1) {
            try {
                resId = Integer.parseInt(segments.get(0));
            } catch (NumberFormatException e) {
                postError(
                        result,
                        "INVALID_URI",
                        "Invalid numeric resource ID in '" + rawUri + "'. Expected android.resource://<pkg>/<id> or android.resource://<pkg>/<type>/<name>.");
                return;
            }
        } else if (segments.size() == 2) {
            resId = resources.getIdentifier(segments.get(1), segments.get(0), packageName);
        } else {
            postError(
                    result,
                    "INVALID_URI",
                    "Invalid android.resource URI format '" + rawUri + "'. Expected android.resource://<pkg>/<id> or android.resource://<pkg>/<type>/<name>.");
            return;
        }

        if (resId == 0) {
            postError(result, "RESOURCE_NOT_FOUND", "Android resource not found for '" + rawUri + "'.");
            return;
        }

        String hintExt = null;
        try {
            final TypedValue tv = new TypedValue();
            resources.getValue(resId, tv, true);
            if (tv.string != null) {
                hintExt = extractExtensionFromPath(tv.string.toString());
            }
        } catch (Resources.NotFoundException ignored) {
            // Fall through; openRawResourceFd/openRawResource will report if invalid.
        }

        try (AssetFileDescriptor afd = resources.openRawResourceFd(resId)) {
            if (afd != null && afd.getParcelFileDescriptor() != null) {
                final long startOffset = Math.max(0L, afd.getStartOffset());
                final long length = afd.getDeclaredLength();
                final int detachedFd = afd.getParcelFileDescriptor().detachFd();
                final Map<String, Object> out = new HashMap<>();
                out.put("kind", "fd");
                out.put("fd", detachedFd);
                out.put("offset", startOffset);
                if (length >= 0L) {
                    out.put("length", length);
                }
                if (hintExt != null) {
                    out.put("hintExt", hintExt);
                }
                postSuccess(result, out);
                return;
            }
        } catch (Resources.NotFoundException | IOException ignored) {
            // Compressed raw assets cannot open directly as an FD; try InputStream fallback below.
        }

        try (InputStream is = resources.openRawResource(resId)) {
            final byte[] bytes = readAllBytes(is);
            final Map<String, Object> out = new HashMap<>();
            out.put("kind", "bytes");
            out.put("bytes", bytes);
            if (hintExt != null) {
                out.put("hintExt", hintExt);
            }
            postSuccess(result, out);
        } catch (Resources.NotFoundException e) {
            postError(
                    result,
                    "RESOURCE_NOT_FOUND",
                    "Android resource not found '" + rawUri + "': " + e.getMessage());
        } catch (IOException e) {
            postError(
                    result,
                    "FILE_NOT_FOUND",
                    "Failed reading compressed Android resource '" + rawUri + "': " + e.getMessage());
        }
    }

    private static byte[] readAllBytes(@NonNull InputStream is) throws IOException {
        final ByteArrayOutputStream baos = new ByteArrayOutputStream();
        final byte[] buf = new byte[8192];
        int n;
        while ((n = is.read(buf)) != -1) {
            baos.write(buf, 0, n);
        }
        return baos.toByteArray();
    }

    private static String extractExtensionFromPath(String path) {
        if (path == null) return null;
        final int slash = path.lastIndexOf('/');
        final int dot = path.lastIndexOf('.');
        if (dot > slash && dot + 1 < path.length()) {
            return path.substring(dot + 1).toLowerCase(Locale.ROOT);
        }
        return null;
    }

    private static String extractExtensionFromMime(String mime) {
        if (mime == null || mime.isEmpty()) return null;
        final String lower = mime.toLowerCase(Locale.ROOT);
        switch (lower) {
            case "audio/mpeg":
            case "audio/mp3":
                return "mp3";
            case "audio/mp4":
            case "audio/m4a":
            case "audio/x-m4a":
                return "m4a";
            case "audio/aac":
            case "audio/aacp":
                return "aac";
            case "audio/ogg":
            case "application/ogg":
                return "ogg";
            case "audio/opus":
                return "opus";
            case "audio/flac":
            case "audio/x-flac":
                return "flac";
            case "audio/wav":
            case "audio/x-wav":
            case "audio/wave":
                return "wav";
            default:
                final String mapped = MimeTypeMap.getSingleton().getExtensionFromMimeType(lower);
                return (mapped == null || mapped.isEmpty()) ? null : mapped.toLowerCase(Locale.ROOT);
        }
    }
}
