package com.sshapp.ssh_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps the app in the foreground while SSH sessions are open, so Android
 * neither cuts its network nor freezes it when the user switches apps.
 *
 * Flutter reports the active sessions through [update]. The notification's
 * Disconnect action goes back to Flutter through [onDisconnectRequested].
 */
class SessionForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            labels = emptyList()
            onDisconnectRequested?.invoke()
            stopForegroundAndSelf()
            return START_NOT_STICKY
        }
        startPending = false
        // startForegroundService() has to be answered with startForeground(),
        // even when the sessions ended while the service was starting.
        try {
            startInForeground()
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not move the service to the foreground", e)
            stopSelf()
            return START_NOT_STICKY
        }
        if (labels.isEmpty()) {
            stopForegroundAndSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (running === this) {
            running = null
        }
        super.onDestroy()
    }

    private fun startInForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = this
    }

    private fun showNotification() {
        getSystemService(NotificationManager::class.java)
            ?.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun stopForegroundAndSelf() {
        if (running === this) {
            running = null
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "SSH sessions",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.description = "Shown while SSH sessions are connected"
            channel.setShowBadge(false)
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }

        val count = labels.size
        val title = if (count == 1) "1 SSH session active" else "$count SSH sessions active"
        // Same as tapping the launcher icon: brings the running task forward.
        val openApp = Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        val disconnect = Intent(this, SessionForegroundService::class.java)
            .setAction(ACTION_DISCONNECT)
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val icon = Icon.createWithResource(this, R.drawable.ic_stat_ssh)

        val builder = notificationBuilder()
            .setSmallIcon(R.drawable.ic_stat_ssh)
            .setContentTitle(title)
            .setContentText(labels.joinToString(", "))
            .setContentIntent(PendingIntent.getActivity(this, 0, openApp, flags))
            .addAction(
                Notification.Action.Builder(
                    icon,
                    "Disconnect",
                    PendingIntent.getService(this, 1, disconnect, flags),
                ).build(),
            )
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    @Suppress("DEPRECATION")
    private fun notificationBuilder(): Notification.Builder {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
    }

    companion object {
        private const val TAG = "SessionForegroundSvc"
        private const val CHANNEL_ID = "ssh_sessions"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_UPDATE = "com.sshapp.ssh_app.action.UPDATE_SESSIONS"
        private const val ACTION_DISCONNECT = "com.sshapp.ssh_app.action.DISCONNECT_ALL"

        /** Called on the main thread when Disconnect is tapped. */
        var onDisconnectRequested: (() -> Unit)? = null

        /** Labels of the active sessions; empty when there are none. */
        private var labels: List<String> = emptyList()

        /** The service while it is in the foreground. */
        private var running: SessionForegroundService? = null

        /** A startForegroundService() call has not reached onStartCommand yet. */
        private var startPending = false

        /** Shows [activeLabels] in the notification, starting the service if
         * needed, or stops it when the list is empty. Main thread only. */
        fun update(context: Context, activeLabels: List<String>) {
            labels = activeLabels
            val service = running
            if (activeLabels.isEmpty()) {
                // A start still on its way stops itself in onStartCommand:
                // stopping a service before it calls startForeground() crashes
                // the app.
                service?.stopForegroundAndSelf()
                return
            }
            if (service != null) {
                service.showNotification()
                return
            }
            if (startPending) {
                // onStartCommand will show the latest labels.
                return
            }
            val intent = Intent(context, SessionForegroundService::class.java)
                .setAction(ACTION_UPDATE)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                startPending = true
            } catch (e: RuntimeException) {
                // Android 12 and later refuse while the app is in the background.
                Log.w(TAG, "Could not start the foreground service", e)
            }
        }
    }
}
