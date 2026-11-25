package com.mawarikhlas.hd_clean

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service that keeps the process alive while an export runs, so a
 * long video is not killed when the user switches apps. The encoding itself
 * runs in [VideoEngine]; this only holds the notification.
 */
class ExportService : Service() {

    companion object {
        private const val CHANNEL = "hdclean_export"
        private const val ID = 7301
        private var running = false

        fun start(ctx: Context) {
            if (running) return
            try {
                ctx.startForegroundService(Intent(ctx, ExportService::class.java))
                running = true
            } catch (_: Exception) {
                // Background-start restrictions: processing continues in the
                // foreground activity; only the background guarantee is lost.
            }
        }

        fun stop(ctx: Context) {
            if (!running) return
            running = false
            ctx.stopService(Intent(ctx, ExportService::class.java))
        }

        fun update(ctx: Context, percent: Int) {
            if (!running) return
            val nm = ctx.getSystemService(NotificationManager::class.java)
            try { nm.notify(ID, build(ctx, percent)) } catch (_: SecurityException) {}
        }

        private fun build(ctx: Context, percent: Int): Notification {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL, "Video optimization", NotificationManager.IMPORTANCE_LOW))
            }
            val open = PendingIntent.getActivity(
                ctx, 0, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(ctx, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_menu_upload)
                .setContentTitle("HD CLEAN is optimizing your video")
                .setContentText(if (percent >= 0) "$percent%" else "Preparing…")
                .setProgress(100, percent.coerceAtLeast(0), percent < 0)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .build()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val type = when {
            Build.VERSION.SDK_INT >= 35 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
            Build.VERSION.SDK_INT >= 29 -> ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            else -> 0
        }
        try {
            ServiceCompat.startForeground(this, ID, build(this, -1), type)
        } catch (_: Exception) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
