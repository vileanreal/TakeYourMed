package com.vileanreal.take_your_med

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val alarmHostChannel = "take_your_med/alarm_host"
    private var wasStopped = false
    private var openedByExternalAlarm = false

    override fun onCreate(savedInstanceState: Bundle?) {
        openedByExternalAlarm = savedInstanceState?.getBoolean("openedByExternalAlarm")
            ?: isNotificationIntent(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        openedByExternalAlarm = if (isNotificationIntent(intent)) {
            wasStopped
        } else {
            false
        }
        super.onNewIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        wasStopped = false
    }

    override fun onStop() {
        wasStopped = true
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("openedByExternalAlarm", openedByExternalAlarm)
        super.onSaveInstanceState(outState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            alarmHostChannel,
        ).setMethodCallHandler { call, result ->
            if (call.method != "dismissAlarmHost") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (!openedByExternalAlarm) {
                result.success(false)
                return@setMethodCallHandler
            }
            openedByExternalAlarm = false
            result.success(true)
            window.decorView.post { finishAndRemoveTask() }
        }
    }

    private fun isNotificationIntent(intent: Intent?): Boolean {
        return intent?.action == "SELECT_NOTIFICATION" ||
            intent?.action == "SELECT_FOREGROUND_NOTIFICATION"
    }
}
