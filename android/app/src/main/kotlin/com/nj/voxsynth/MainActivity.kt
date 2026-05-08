package com.nj.voxsynth

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity : FlutterActivity() {
    private val pathsChannelName = "com.nj.voxsynth/paths"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Defensive registration: when a custom engine/path channel is in play,
        // ensure all generated plugins (including `record`) are attached.
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pathsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getApplicationDocumentsPath" ->
                        result.success(applicationContext.filesDir.absolutePath)
                    "getApplicationSupportPath" ->
                        result.success(applicationContext.filesDir.absolutePath)
                    "getTemporaryPath" ->
                        result.success(applicationContext.cacheDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
    }
}
