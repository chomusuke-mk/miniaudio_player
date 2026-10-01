package com.example.miniaudio_player

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "dev.chomusuke.miniaudio_player/devices"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAudioDevices" -> {
                        try {
                            val devices = getAudioDevices()
                            result.success(devices)
                        } catch (e: Exception) {
                            result.error("DEVICE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun getAudioDevices(): List<Map<String, Any>> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return emptyList()
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val resultList = mutableListOf<Map<String, Any>>()

        var hasFoundDefault = false
        for (device in devices) {
            if (device.type == AudioDeviceInfo.TYPE_TELEPHONY ||
                device.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE ||
                device.type == AudioDeviceInfo.TYPE_REMOTE_SUBMIX) {
                // Skip non-media output devices
                continue
            }

            val isDefault = if (!hasFoundDefault) {
                isDefaultOutput(device, audioManager)
            } else {
                false
            }
            if (isDefault) {
                hasFoundDefault = true
            }

            val map = hashMapOf<String, Any>(
                "id" to device.id.toString(),
                "name" to resolveDeviceName(device),
                "isDefault" to isDefault,
                "type" to device.type
            )
            resultList.add(map)
        }

        return resultList
    }

    private fun resolveDeviceName(device: AudioDeviceInfo): String {
        val prodName = device.productName?.toString()?.trim()
        val typeFallback = when (device.type) {
            AudioDeviceInfo.TYPE_AUX_LINE -> "AUX Line"
            AudioDeviceInfo.TYPE_BLE_BROADCAST -> "BLE Broadcast"
            AudioDeviceInfo.TYPE_BLE_HEADSET -> "BLE Headset"
            AudioDeviceInfo.TYPE_BLE_SPEAKER -> "BLE Speaker"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth Audio"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth Headset"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Earpiece"
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Built-in Microphone"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Speaker"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "Speaker (Safe)"
            AudioDeviceInfo.TYPE_BUS -> "Bus Audio"
            AudioDeviceInfo.TYPE_DOCK -> "Dock Audio"
            AudioDeviceInfo.TYPE_DOCK_ANALOG -> "Dock Analog"
            AudioDeviceInfo.TYPE_FM -> "FM Radio"
            AudioDeviceInfo.TYPE_FM_TUNER -> "FM Tuner"
            AudioDeviceInfo.TYPE_HDMI -> "HDMI"
            AudioDeviceInfo.TYPE_HDMI_ARC -> "HDMI ARC"
            AudioDeviceInfo.TYPE_HDMI_EARC -> "HDMI eARC"
            AudioDeviceInfo.TYPE_HEARING_AID -> "Hearing Aid"
            AudioDeviceInfo.TYPE_IP -> "IP Audio"
            AudioDeviceInfo.TYPE_LINE_ANALOG -> "Line Analog"
            AudioDeviceInfo.TYPE_LINE_DIGITAL -> "Line Digital"
            AudioDeviceInfo.TYPE_MULTICHANNEL_GROUP -> "Multichannel Group"
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> "Remote Submix"
            AudioDeviceInfo.TYPE_TELEPHONY -> "Telephony"
            AudioDeviceInfo.TYPE_TV_TUNER -> "TV Tuner"
            AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB Audio Accessory"
            AudioDeviceInfo.TYPE_USB_DEVICE -> "USB Audio Device"
            AudioDeviceInfo.TYPE_USB_HEADSET -> "USB Headset"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Wired Headphones"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired Headset"
            else -> "Audio Output (${device.id})"
        }

        if (!prodName.isNullOrEmpty() && prodName.lowercase() != "default") {
            return "$prodName ($typeFallback)"
        }
        return typeFallback
    }

    @Suppress("DEPRECATION")
    private fun isDefaultOutput(device: AudioDeviceInfo, audioManager: AudioManager): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val commDevice = audioManager.communicationDevice
            if (commDevice != null && commDevice.id == device.id) {
                return true
            }
        }
        return when (device.type) {
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET -> audioManager.isWiredHeadsetOn
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> audioManager.isBluetoothA2dpOn
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> !audioManager.isWiredHeadsetOn && !audioManager.isBluetoothA2dpOn
            else -> false
        }
    }
}
