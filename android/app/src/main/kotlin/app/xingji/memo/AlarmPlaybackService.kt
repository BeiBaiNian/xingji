package app.xingji.memo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.database.ContentObserver
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Handler
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import org.json.JSONObject
import java.util.UUID

data class RingPresentation(val token: String, val title: String, val startedAt: Long, val lockScreen: Boolean)

/** Exists only while an opted-in alarm is sounding; no always-on service. */
class AlarmPlaybackService : Service() {
    companion object {
        private const val CHANNEL = "xingji_alarm_playback"
        private const val IN_APP_CHANNEL = "xingji_alarm_in_app"
        private const val NOTIFICATION = 31027
        private var active: AlarmPlaybackService? = null
        private val listeners = mutableSetOf<() -> Unit>()
        fun current(): RingPresentation? = active?.let {
            if (it.stopping) null else it.presentation
        }
        fun observe(listener: () -> Unit) { listeners.add(listener) }
        fun removeObserver(listener: () -> Unit) { listeners.remove(listener) }
        private fun changed() { listeners.toList().forEach { it() } }
        fun dismiss(token: String, snooze: Boolean = false): Boolean {
            val service = active ?: return false
            if (service.stopping || service.presentation?.token != token) return false
            if (snooze) service.item?.let { Reminders.snoozeAlarm(service, it) }
            service.finishRinging(if (snooze) "snoozed" else "dismissed")
            return true
        }
        fun createChannels(c: Context) {
            val manager = c.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "闹铃提醒", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(null, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            })
        }
        fun channelAllowed(c: Context): Boolean {
            createChannels(c)
            val manager = c.getSystemService(NotificationManager::class.java)
            return manager.areNotificationsEnabled() && manager.getNotificationChannel(CHANNEL).importance != NotificationManager.IMPORTANCE_NONE
        }
        fun start(c: Context, item: JSONObject) {
            check(channelAllowed(c))
            c.startForegroundService(Intent(c, AlarmPlaybackService::class.java)
                .setAction("ring").putExtra("item", item.toString()))
        }
        fun stop(c: Context, id: String? = null) {
            if (active != null && (id == null || active?.item?.optString("id") == id)) {
                active?.finishRinging("cancelled")
            }
        }
        fun retain(c: Context, ids: Set<String>, enabled: Boolean) {
            val id = active?.item?.optString("id") ?: return
            if (!enabled || id != "test" && id != ReminderDiagnostics.TIMED_TEST && id !in ids) stop(c)
        }
    }
    private val handler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var focus: AudioFocusRequest? = null
    private var wake: PowerManager.WakeLock? = null
    private var item: JSONObject? = null
    private var presentation: RingPresentation? = null
    private var stopping = false
    private var playbackStarted = 0L
    private var screenOnSeen = false
    private val volumeStreams = intArrayOf(AudioManager.STREAM_ALARM, AudioManager.STREAM_MUSIC,
        AudioManager.STREAM_RING, AudioManager.STREAM_NOTIFICATION)
    private var volumes = emptyList<Int>()
    private fun readVolumes(): List<Int> = getSystemService(AudioManager::class.java).let { audio ->
        volumeStreams.map { audio.getStreamVolume(it) }
    }
    private val volumeObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) {
            val next = readVolumes()
            if (!stopping && playbackStarted != 0L && android.os.SystemClock.elapsedRealtime() - playbackStarted > 750 &&
                volumes.isNotEmpty() && next != volumes) finishRinging("volume changed")
            volumes = next
        }
    }
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_ON) screenOnSeen = true
            if (intent.action == Intent.ACTION_SHUTDOWN || intent.action == Intent.ACTION_SCREEN_OFF &&
                screenOnSeen && !getSystemService(PowerManager::class.java).isInteractive) finishRinging("screen off or shutdown")
        }
    }
    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        active = this
        volumes = readVolumes()
        contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, volumeObserver)
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF).apply { addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SHUTDOWN) }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenReceiver, filter, RECEIVER_NOT_EXPORTED)
        else registerReceiver(screenReceiver, filter)
    }
    private fun action(name: String, token: String): PendingIntent = PendingIntent.getService(this, 0,
        Intent(this, AlarmPlaybackService::class.java).setAction(name)
            .setData(Uri.parse("xingji-ring://$name/$token")).putExtra("token", token),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = try {
        handleStart(intent)
    } catch (e: Exception) {
        ReminderDiagnostics.record(this, "service_failed", item?.optString("id").orEmpty(), error = e)
        finishWithNotification("service failed")
        START_NOT_STICKY
    }

    private fun handleStart(intent: Intent?): Int {
        if (intent?.action == "stop" || intent?.action == "snooze") {
            if (!dismiss(intent.getStringExtra("token") ?: "", intent.action == "snooze") && item == null) stopSelf()
            return START_NOT_STICKY
        }
        val value = try { JSONObject(intent?.getStringExtra("item") ?: "") } catch (_: Exception) {
            stopSelf(); return START_NOT_STICKY
        }
        if (!Reminders.isCurrent(this, value)) {
            ReminderDiagnostics.record(this, "stale_service_ignored", value.optString("id"))
            if (item == null) stopSelf()
            return START_NOT_STICKY
        }
        item?.let { previous ->
            if (previous.optString("id") != value.optString("id")) {
                Reminders.show(this, JSONObject(previous.toString()).put("alarm", false))
            }
        }
        releaseAudio()
        stopping = false
        item = value
        playbackStarted = 0L
        screenOnSeen = getSystemService(PowerManager::class.java).isInteractive
        val lockScreen = getSystemService(KeyguardManager::class.java).isKeyguardLocked ||
            !getSystemService(PowerManager::class.java).isInteractive
        val host = if (lockScreen) null else AlarmActivity.foregroundActivity ?: MainActivity.foregroundActivity
        val view = RingPresentation(UUID.randomUUID().toString(),
            value.optString("title", "星记 · 闹铃提醒"), System.currentTimeMillis(), lockScreen)
        presentation = view
        volumes = readVolumes()
        val manager = getSystemService(NotificationManager::class.java)
        // The native window provides the controls in-app; avoid a second heads-up card covering it.
        val channel = if (host == null) CHANNEL else IN_APP_CHANNEL
        manager.createNotificationChannel(NotificationChannel(channel,
            if (host == null) "闹铃提醒" else "应用内闹铃状态",
            if (host == null) NotificationManager.IMPORTANCE_HIGH else NotificationManager.IMPORTANCE_LOW).apply {
            description = "用户开启的闹铃，使用系统闹钟音量，最长响铃 60 秒"
            setSound(null, attributes)
            enableVibration(false)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
        val open = AlarmActivity.pending(this, view.token)
        val builder = Notification.Builder(this, channel)
            .setSmallIcon(R.drawable.ic_notify)
            .setContentTitle(value.optString("title", "星记 · 闹铃提醒"))
            .setContentText("闹铃响铃中 · 点击打开关闭界面")
            .setCategory(Notification.CATEGORY_ALARM).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOngoing(true)
            .setContentIntent(open)
            .setDeleteIntent(action("stop", view.token))
            .addAction(Notification.Action.Builder(null, "关闭闹铃", action("stop", view.token)).build())
            .addAction(Notification.Action.Builder(null, "10 分钟后再响", action("snooze", view.token)).build())
        if (host == null && AlarmActivity.fullScreenAllowed(this)) builder.setFullScreenIntent(open, true)
        if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        try {
            startForeground(NOTIFICATION, builder.build())
            ReminderDiagnostics.record(this, "service_foreground", value.optString("id"), value.optLong("at"))
        } catch (e: Exception) {
            ReminderDiagnostics.record(this, "foreground_failed", value.optString("id"), error = e)
            finishWithNotification("foreground failed")
            return START_NOT_STICKY
        }
        // A failed window launch must never prevent the independent notification/audio controls.
        try { host?.let { AlarmActivity.open(it, view.token) } } catch (e: Exception) {
            ReminderDiagnostics.record(this, "window_failed", value.optString("id"), error = e)
        }
        changed()
        handler.postDelayed({ finishWithNotification("timeout") }, 60000)
        try {
            wake = getSystemService(PowerManager::class.java).newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "xingji:alarm").apply { acquire(65000) }
            val audio = getSystemService(AudioManager::class.java)
            focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes).setOnAudioFocusChangeListener { change ->
                    if (presentation?.token == view.token && !stopping &&
                        (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)) finishWithNotification("audio focus lost")
                }.build()
            val focusResult = audio.requestAudioFocus(focus!!)
            ReminderDiagnostics.record(this, "audio_focus", value.optString("id"), detail = if (focusResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) "granted" else "denied")
            if (focusResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                player = MediaPlayer().apply {
                    setAudioAttributes(attributes)
                    setDataSource(this@AlarmPlaybackService, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM))
                    isLooping = true
                    setOnPreparedListener { prepared ->
                        if (presentation?.token == view.token && !stopping && player === prepared) {
                            try {
                                prepared.start()
                                playbackStarted = android.os.SystemClock.elapsedRealtime()
                                volumes = readVolumes()
                                Reminders.markDelivered(this@AlarmPlaybackService, value.getString("id"))
                                ReminderDiagnostics.record(this@AlarmPlaybackService, "playback_started", value.getString("id"), value.optLong("at"))
                            } catch (e: Exception) {
                                ReminderDiagnostics.record(this@AlarmPlaybackService, "playback_failed", value.optString("id"), error = e)
                                finishWithNotification("playback unavailable")
                            }
                        }
                    }
                    setOnErrorListener { _, what, extra ->
                        if (presentation?.token == view.token && !stopping) {
                            ReminderDiagnostics.record(this@AlarmPlaybackService, "playback_failed", value.optString("id"), detail = "$what/$extra")
                            finishWithNotification("playback error")
                        }
                        true
                    }
                    prepareAsync()
                }
            } else {
                finishWithNotification("audio focus denied")
                return START_NOT_STICKY
            }
            getSystemService(Vibrator::class.java).vibrate(
                VibrationEffect.createWaveform(longArrayOf(0, 500, 500), 0))
        } catch (e: Exception) {
            ReminderDiagnostics.record(this, "playback_failed", value.optString("id"), error = e)
            finishWithNotification("playback unavailable")
        }
        return START_NOT_STICKY
    }
    private fun finishWithNotification(reason: String) {
        if (stopping) return
        item?.let { Reminders.show(this, JSONObject(it.toString()).put("alarm", false)) }
        finishRinging(reason)
    }
    private fun finishRinging(reason: String) {
        if (stopping) return
        stopping = true
        ReminderDiagnostics.record(this, "stopped", item?.optString("id").orEmpty(), detail = reason)
        releaseAudio()
        changed()
        stopSelf()
    }
    private fun releaseAudio() {
        handler.removeCallbacksAndMessages(null)
        player?.release(); player = null
        getSystemService(Vibrator::class.java).cancel()
        focus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }; focus = null
        if (wake?.isHeld == true) wake?.release()
        wake = null
    }
    override fun onDestroy() {
        if (!stopping && item != null) ReminderDiagnostics.record(this, "stopped", item!!.optString("id"), detail = "service destroyed")
        stopping = true
        releaseAudio()
        contentResolver.unregisterContentObserver(volumeObserver)
        unregisterReceiver(screenReceiver)
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (active === this) active = null
        changed()
        super.onDestroy()
    }
}
