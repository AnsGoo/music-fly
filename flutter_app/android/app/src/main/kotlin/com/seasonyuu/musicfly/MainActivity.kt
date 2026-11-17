package com.seasonyuu.musicfly

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 必须继承 AudioServiceActivity 而不是 FlutterActivity：audio_service 0.18
// 在 onAttachedToActivity 里比对 plugin 的 messenger 与 Activity 提供的引擎，
// 普通 FlutterActivity 不会把引擎注册进 FlutterEngineCache，检测到不一致就抛
// "The Activity class ... has not provided the correct FlutterEngine"，导致
// AudioService.init() 失败、锁屏/通知栏媒体控制完全不可用。AudioServiceActivity
// 只多 override 了 provideFlutterEngine 返回共享引擎，下面的 MethodChannel 照常注册。
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // FnConnect stable device ID: ANDROID_ID is scoped to the device +
        // user + app signing key and survives uninstall/reinstall (reset only
        // by a factory reset), which is exactly what the fnOS trusted-device
        // (`did`) binding needs. No permission required on Android 8+.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "musicfly/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "androidId" -> result.success(
                        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                    )
                    else -> result.notImplemented()
                }
            }
        // Android 13+ 的媒体通知（锁屏 / 通知栏播放控制器）需要 POST_NOTIFICATIONS
        // 才显示：前台服务通知本身豁免，但暂停后服务退出前台、通知变成普通通知，
        // 没授权就会瞬间消失，用户就点不回播放了。由 Dart 侧在第一次播放时请求，
        // 不在启动时弹窗打扰。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "musicfly/notification")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPostNotifications" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                POST_NOTIFICATIONS_REQUEST
                            )
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        const val POST_NOTIFICATIONS_REQUEST = 4701
    }
}
