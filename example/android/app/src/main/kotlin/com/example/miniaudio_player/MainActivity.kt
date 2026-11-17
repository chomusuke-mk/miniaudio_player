package com.example.miniaudio_player

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.chomusuke.miniaudio_player_example/content_test",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "createMediaStoreWavUri" -> {
                    try {
                        val name = call.argument<String>("displayName")
                            ?: "map_rec_${System.currentTimeMillis()}.wav"
                        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                        } else {
                            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                        }
                        val values = ContentValues().apply {
                            put(MediaStore.Audio.Media.DISPLAY_NAME, name)
                            put(MediaStore.Audio.Media.MIME_TYPE, "audio/wav")
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                put(MediaStore.Audio.Media.RELATIVE_PATH, "Music/MiniaudioPlayerTest")
                            }
                        }
                        val uri = contentResolver.insert(collection, values)
                        if (uri == null) {
                            result.error("INSERT_FAILED", "MediaStore.insert returned null", null)
                        } else {
                            result.success(uri.toString())
                        }
                    } catch (e: Exception) {
                        result.error("INSERT_ERR", e.message, null)
                    }
                }
                "readContentBytes" -> {
                    try {
                        val rawUri = call.argument<String>("uri")!!
                        val uri = Uri.parse(rawUri)
                        contentResolver.openInputStream(uri)?.use { stream ->
                            result.success(stream.readBytes())
                        } ?: result.error("READ_NULL", "openInputStream returned null", null)
                    } catch (e: Exception) {
                        result.error("READ_ERR", e.message, null)
                    }
                }
                "deleteContentUri" -> {
                    try {
                        val rawUri = call.argument<String>("uri")!!
                        val rows = contentResolver.delete(Uri.parse(rawUri), null, null)
                        result.success(rows)
                    } catch (e: Exception) {
                        result.error("DEL_ERR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
