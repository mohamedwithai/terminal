package com.sshapp.ssh_app

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth shows its prompt through a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null
    private var windowChannel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val labels = call.argument<List<String>>("labels") ?: emptyList()
                    SessionForegroundService.update(applicationContext, labels)
                    result.success(null)
                }
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "notify" -> {
                    SessionForegroundService.notifyDone(
                        applicationContext,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("text") ?: "",
                    )
                    result.success(null)
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // FLAG_SECURE hides the app in the recent-apps screen and blocks
        // screenshots. Flutter turns it on while the app lock is enabled.
        val window = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WINDOW_CHANNEL)
        window.setMethodCallHandler { call, result ->
            if (call.method == "setSecure") {
                if (call.argument<Boolean>("secure") == true) {
                    getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        windowChannel = window
        SessionForegroundService.onDisconnectRequested = {
            channel.invokeMethod("disconnectAll", null)
        }
        this.channel = channel
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        SessionForegroundService.onDisconnectRequested = null
        channel?.setMethodCallHandler(null)
        channel = null
        windowChannel?.setMethodCallHandler(null)
        windowChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        // The sessions live in this activity's Flutter engine and end with it.
        SessionForegroundService.update(applicationContext, emptyList())
        super.onDestroy()
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.success(false)
            return
        }
        pendingPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    private fun openNotificationSettings() {
        val appDetails = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null),
        )
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            appDetails
        }
        try {
            startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            // Some builds lack the notification page; the app page links to it.
            startActivity(appDetails)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) {
            return
        }
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        result.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    private companion object {
        const val CHANNEL = "ssh_app/session_foreground_service"
        const val WINDOW_CHANNEL = "ssh_app/window"
        const val NOTIFICATION_PERMISSION_REQUEST = 4201
    }
}
