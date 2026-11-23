package app.xingji.memo

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.media.AudioManager
import android.media.AudioAttributes
import android.provider.Settings
import android.os.PowerManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

object Reminders {
    private const val CHANNEL = "xingji_reminders"
    private const val SCREEN_ON_CHANNEL = "xingji_screen_on_reminders"
    private fun prefs(c: Context) = c.getSharedPreferences("xingji_schedules", Context.MODE_PRIVATE)
    private fun manager(c: Context) = c.getSystemService(NotificationManager::class.java)
    private fun alarms(c: Context) = c.getSystemService(AlarmManager::class.java)
    private fun read(c: Context, name: String) = JSONObject(prefs(c).getString(name, "{}") ?: "{}")
    private fun store(c: Context, name: String, value: JSONObject) {
        check(prefs(c).edit().putString(name, value.toString()).commit())
    }
    fun createChannel(c: Context) {
        manager(c).createNotificationChannel(NotificationChannel(CHANNEL, "备忘录提醒", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "已安排的备忘录与逾期提醒"
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
        manager(c).createNotificationChannel(NotificationChannel(SCREEN_ON_CHANNEL, "亮屏提醒", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "亮屏时显示顶部提醒并播放一次通知提示音"
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            setSound(Settings.System.DEFAULT_NOTIFICATION_URI, AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
        })
    }
    private fun allowed(c: Context, channel: String = CHANNEL) = manager(c).areNotificationsEnabled() &&
        manager(c).getNotificationChannel(channel)?.importance != NotificationManager.IMPORTANCE_NONE
    private fun exact(c: Context) = Build.VERSION.SDK_INT < 31 || alarms(c).canScheduleExactAlarms()
    @Synchronized fun state(c: Context): Map<String, Any> {
        createChannel(c)
        AlarmPlaybackService.createChannels(c)
        val schedules = read(c, "items")
        val registrations = read(c, "registrations")
        val now = System.currentTimeMillis()
        val future = schedules.keys().asSequence().map { schedules.getJSONObject(it) }.filter { it.optLong("at") > now }.toList()
        return mapOf("allowed" to allowed(c), "hotkey" to false, "exact" to exact(c),
            "screenOnAllowed" to allowed(c, SCREEN_ON_CHANNEL),
            "screenOnHighPriority" to (manager(c).getNotificationChannel(SCREEN_ON_CHANNEL).importance >= NotificationManager.IMPORTANCE_HIGH),
            "screenOnSound" to (manager(c).getNotificationChannel(SCREEN_ON_CHANNEL).sound != null),
            "notificationsAllowed" to manager(c).areNotificationsEnabled(),
            "alarmChannelAllowed" to AlarmPlaybackService.channelAllowed(c),
            "alarmChannelHighPriority" to (manager(c).getNotificationChannel("xingji_alarm_playback").importance >= NotificationManager.IMPORTANCE_HIGH),
            "fullScreen" to AlarmActivity.fullScreenAllowed(c),
            "scheduled" to future.size,
            "registrationFailures" to future.count { registrations.optJSONObject(it.getString("id"))?.optString("mode") == "failed" },
            "inexactSchedules" to future.count { registrations.optJSONObject(it.getString("id"))?.optString("mode") == "inexact" },
            "nextAt" to (future.minOfOrNull { it.getLong("at") } ?: 0L),
            "timedTest" to ReminderDiagnostics.test(c),
            "systemClockTest" to SystemClockTest.state(c),
            "clockBackgroundAllowed" to SystemClockReminders.backgroundAllowed(c),
            "clockAvailable" to SystemClockReminders.available(c),
            "clockReminder" to SystemClockReminders.latest(c),
            "batteryOptimized" to !c.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(c.packageName),
            "manufacturer" to Build.MANUFACTURER,
            "delivered" to read(c, "delivered").keys().asSequence().toList(),
            "alarmVolume" to c.getSystemService(AudioManager::class.java).getStreamVolume(AudioManager.STREAM_ALARM))
    }
    private fun pending(c: Context, id: String, at: Long = 0) = PendingIntent.getBroadcast(c, 0,
        Intent(c, ReminderReceiver::class.java).apply {
            data = Uri.Builder().scheme("xingji-alarm").authority("reminder").appendPath(id).build()
            putExtra("id", id)
            putExtra("at", at)
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun schedule(c: Context, item: JSONObject) {
        val time = item.getLong("at")
        if (time <= System.currentTimeMillis()) return
        val id = item.getString("id")
        val operation = pending(c, id, time)
        var mode = "failed"
        try {
            if (exact(c) && item.optBoolean("alarm")) {
                val open = PendingIntent.getActivity(c, 31028, Intent(c, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                alarms(c).setAlarmClock(AlarmManager.AlarmClockInfo(time, open), operation)
                mode = "alarm_clock"
            }
            else if (exact(c)) {
                alarms(c).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, time, operation)
                mode = "exact"
            } else {
                alarms(c).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, time, operation)
                mode = "inexact"
            }
        } catch (e: Exception) {
            ReminderDiagnostics.record(c, "registration_error", id, time, error = e)
            try {
                alarms(c).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, time, operation)
                mode = "inexact"
            } catch (fallback: Exception) {
                ReminderDiagnostics.record(c, "registration_failed", id, time, error = fallback)
            }
        }
        val registrations = read(c, "registrations")
        val previous = registrations.optJSONObject(id)
        if (previous?.optLong("at") != time || previous?.optString("mode") != mode) {
            store(c, "registrations", registrations.put(id, JSONObject().put("at", time).put("mode", mode)))
            ReminderDiagnostics.record(c, if (mode == "failed") "registration_failed" else "schedule_submitted", id, time, mode)
        }
    }
    @Synchronized fun replace(c: Context, rows: List<Map<String, Any?>>, removed: List<String>, active: List<String>, alarmMode: Boolean) {
        val old = read(c, "items")
        val next = JSONObject()
        val activeIds = active.toSet()
        val now = System.currentTimeMillis()
        check(prefs(c).edit().putString("active", JSONArray(active).toString()).commit())
        for (row in rows.take(480)) {
            val source = JSONObject(row)
            val id = source.getString("id")
            next.put(id, JSONObject().put("id", id).put("at", source.getLong("at"))
                .put("title", source.optString("title", "星记 · 有一项备忘录到期"))
                .put("body", source.optString("body", "打开星记查看详情。"))
                .put("uri", source.optString("uri", "xingji://open"))
                .put("actions", source.optBoolean("actions")).put("alarm", source.optBoolean("alarm"))
                .put("systemClock", source.optBoolean("systemClock", source.optBoolean("alarm")))
                .put("forceAlarm", source.optBoolean("forceAlarm")))
        }
        // Flutter omits due rows from its future projection. Keep the receiver's payload
        // across a concurrent sync until the due broadcast has had time to arrive.
        for (id in old.keys()) {
            val previous = old.getJSONObject(id)
            if (!next.has(id) && id in activeIds && previous.optLong("at") >= now - 60000 &&
                previous.optLong("at") <= now + 2000) {
                next.put(id, JSONObject(previous.toString()).put("alarm", alarmMode && previous.optBoolean("alarm")))
            }
        }
        val test = read(c, "timedTest")
        if (alarmMode && test.optLong("at") >= now - 60000 && test.has("id")) next.put(ReminderDiagnostics.TIMED_TEST, test)
        else if (test.has("id")) {
            if (!alarmMode) ReminderDiagnostics.record(c, "test_cancelled", ReminderDiagnostics.TIMED_TEST)
            store(c, "timedTest", JSONObject())
        }
        val snoozes = read(c, "snoozes")
        for (id in snoozes.keys().asSequence().toList()) {
            if (!alarmMode || id !in activeIds && id != "test" && id != ReminderDiagnostics.TIMED_TEST) snoozes.remove(id)
            else if (snoozes.getJSONObject(id).optLong("at") > System.currentTimeMillis()) next.put(id, snoozes.getJSONObject(id))
            else snoozes.remove(id)
        }
        store(c, "snoozes", snoozes)
        AlarmPlaybackService.retain(c, activeIds, alarmMode)
        // Persist before registering, so a process exit or reboot can recover.
        store(c, "items", next)
        val registrations = read(c, "registrations")
        val requests = read(c, "requests")
        for (id in old.keys().asSequence().toList()) if (!next.has(id)) {
            alarms(c).cancel(pending(c, id)); registrations.remove(id); requests.remove(id)
            ReminderDiagnostics.record(c, "schedule_cancelled", id)
        }
        store(c, "registrations", registrations)
        store(c, "requests", requests)
        ReminderDiagnostics.record(c, "projection_saved", detail = "count=${next.length()}")
        for (id in next.keys()) schedule(c, next.getJSONObject(id))
        val delivered = read(c, "delivered")
        for (id in next.keys()) {
            if (old.has(id) && old.getJSONObject(id).optLong("at") != next.getJSONObject(id).optLong("at")) delivered.remove(id)
        }
        val tokens = read(c, "tokens")
        val cancelled = removed.toMutableSet()
        for (id in delivered.keys()) if (id != "test" && id != "overdue" && id != ReminderDiagnostics.TIMED_TEST && id !in activeIds) cancelled.add(id)
        for (id in cancelled) { manager(c).cancel(id, 0); delivered.remove(id) }
        for (token in tokens.keys().asSequence().toList()) {
            if (tokens.getJSONObject(token).optString("id") in cancelled) tokens.remove(token)
        }
        store(c, "delivered", delivered)
        store(c, "tokens", tokens)
    }
    fun launch(c: Context, id: String, uri: String): PendingIntent {
        val token = UUID.randomUUID().toString()
        val tokens = read(c, "tokens")
        tokens.put(token, JSONObject().put("id", id).put("event", uri))
        while (tokens.length() > 1600) tokens.remove(tokens.keys().next())
        store(c, "tokens", tokens)
        return PendingIntent.getActivity(c, 0, Intent(c, MainActivity::class.java).apply {
            data = Uri.parse("xingji-notification://$token")
            putExtra("notification_token", token)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    @Synchronized fun consumeActivation(c: Context, intent: Intent?): String {
        val token = intent?.getStringExtra("notification_token") ?: return ""
        intent.removeExtra("notification_token")
        val tokens = read(c, "tokens")
        val entry = tokens.optJSONObject(token) ?: return ""
        // Opening an old ordinary notification must not silence a later snoozed ring.
        // Only the current ring's token-bearing controls may dismiss it.
        tokens.remove(token)
        store(c, "tokens", tokens)
        return entry.optString("event")
    }
    @Synchronized fun show(c: Context, item: JSONObject) {
        createChannel(c)
        val id = item.getString("id")
        if (SystemClockReminders.usesClock(item)) {
            val interactive = c.getSystemService(PowerManager::class.java).isInteractive
            // Per-memo forceAlarm rings through the system clock even while the screen is on.
            val forced = item.optBoolean("forceAlarm")
            ReminderDiagnostics.record(c, "reminder_route", id, item.optLong("at"),
                if (forced) "forced_alarm_clock" else if (interactive) "screen_on_notification" else "screen_off_clock")
            if (interactive && !forced) {
                show(c, JSONObject(item.toString()).put("alarm", false).put("systemClock", false).put("screenOn", true))
                return
            }
            if (SystemClockReminders.dispatch(c, item)) {
                // Handled by another app, not proof that it has started playing.
                markDelivered(c, id)
                return
            }
            show(c, JSONObject(item.toString()).put("alarm", false).put("systemClock", false)
                .put("body", "系统时钟交接未确认，请在星记设置中查看权限与诊断。"))
            return
        }
        if (!manager(c).areNotificationsEnabled()) {
            ReminderDiagnostics.record(c, "notification_blocked", id, detail = "app_notifications")
            return
        }
        if (item.optBoolean("alarm") && (exact(c) || id == "test")) {
            try {
                AlarmPlaybackService.start(c, item)
                ReminderDiagnostics.record(c, "service_requested", id, item.optLong("at"))
                return
            } catch (e: Exception) { ReminderDiagnostics.record(c, "service_start_failed", id, error = e) }
        } else if (item.optBoolean("alarm")) {
            ReminderDiagnostics.record(c, "alarm_unavailable", id, detail = "exact_permission_missing")
        }
        val channel = if (item.optBoolean("screenOn")) SCREEN_ON_CHANNEL else CHANNEL
        if (!allowed(c, channel)) {
            ReminderDiagnostics.record(c, "notification_blocked", id, detail = "reminder_channel")
            return
        }
        val uri = item.optString("uri", "xingji://open")
        val builder = Notification.Builder(c, channel)
            .setSmallIcon(R.drawable.ic_notify)
            .setContentTitle(item.optString("title", "星记 · 提醒"))
            .setContentText(item.optString("body", "打开星记查看详情。"))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(launch(c, id, uri))
        if (item.optBoolean("actions")) {
            val parsed = Uri.parse(uri)
            builder.addAction(Notification.Action.Builder(null, "完成本次",
                launch(c, id, parsed.buildUpon().authority("complete").build().toString())).build())
            builder.addAction(Notification.Action.Builder(null, "稍后 10 分钟",
                launch(c, id, parsed.buildUpon().authority("snooze").appendQueryParameter("minutes", "10").build().toString())).build())
        }
        try {
            manager(c).notify(id, 0, builder.build())
            markDelivered(c, id)
            ReminderDiagnostics.record(c, "notification_posted", id, item.optLong("at"))
        } catch (e: Exception) { ReminderDiagnostics.record(c, "notification_failed", id, error = e) }
    }
    @Synchronized fun markDelivered(c: Context, id: String) {
        val delivered = read(c, "delivered").put(id, System.currentTimeMillis())
        while (delivered.length() > 1600) delivered.remove(delivered.keys().next())
        store(c, "delivered", delivered)
    }
    @Synchronized fun isCurrent(c: Context, source: JSONObject): Boolean {
        val id = source.optString("id")
        return id == "test" || read(c, "items").optJSONObject(id)?.optLong("at") == source.optLong("at")
    }
    @Synchronized fun fire(c: Context, id: String, expectedAt: Long) {
        val item = read(c, "items").optJSONObject(id)
        if (item == null) {
            ReminderDiagnostics.record(c, "trigger_ignored", id, detail = "payload_missing_or_cancelled"); return
        }
        if (expectedAt != 0L && expectedAt != item.optLong("at")) {
            ReminderDiagnostics.record(c, "stale_trigger_ignored", id); return
        }
        if (item.optLong("at") > System.currentTimeMillis() + 2000) {
            ReminderDiagnostics.record(c, "trigger_ignored", id, detail = "too_early"); return
        }
        if (read(c, "delivered").has(id)) {
            ReminderDiagnostics.record(c, "trigger_ignored", id, detail = "already_handled"); return
        }
        val requests = read(c, "requests")
        val previous = requests.optJSONObject(id)
        val same = previous?.optLong("at") == item.optLong("at")
        if (same && (System.currentTimeMillis() - previous!!.optLong("time") < 10000 || previous.optInt("count") >= 2)) return
        requests.put(id, JSONObject().put("at", item.optLong("at")).put("time", System.currentTimeMillis())
            .put("count", if (same) previous!!.optInt("count") + 1 else 1))
        store(c, "requests", requests)
        show(c, item)
    }
    @Synchronized fun scheduleTest(c: Context, systemClock: Boolean = true): Map<String, Any> {
        val id = ReminderDiagnostics.TIMED_TEST
        cancelTest(c)
        val item = JSONObject().put("id", id).put("at", System.currentTimeMillis() + 30000)
            .put("alarm", true).put("systemClock", systemClock)
            .put("title", "星记 · 定时闹铃测试").put("uri", "xingji://open")
        val delivered = read(c, "delivered"); delivered.remove(id); store(c, "delivered", delivered)
        val requests = read(c, "requests"); requests.remove(id); store(c, "requests", requests)
        store(c, "timedTest", item)
        store(c, "items", read(c, "items").put(id, item))
        ReminderDiagnostics.record(c, "test_scheduled", id, item.getLong("at"))
        schedule(c, item)
        return state(c)
    }
    @Synchronized fun cancelTest(c: Context) {
        val id = ReminderDiagnostics.TIMED_TEST
        alarms(c).cancel(pending(c, id))
        AlarmPlaybackService.stop(c, id)
        for (name in listOf("items", "snoozes", "requests", "registrations", "delivered")) {
            val value = read(c, name); value.remove(id); store(c, name, value)
        }
        store(c, "timedTest", JSONObject())
        ReminderDiagnostics.record(c, "test_cancelled", id)
    }
    @Synchronized fun snoozeAlarm(c: Context, source: JSONObject) {
        val id = source.getString("id")
        val active = JSONArray(prefs(c).getString("active", "[]"))
        if (id != "test" && id != ReminderDiagnostics.TIMED_TEST && (0 until active.length()).none { active.getString(it) == id }) return
        val item = JSONObject(source.toString()).put("at", System.currentTimeMillis() + 10 * 60 * 1000)
        store(c, "snoozes", read(c, "snoozes").put(id, item))
        store(c, "items", read(c, "items").put(id, item))
        val delivered = read(c, "delivered"); delivered.remove(id); store(c, "delivered", delivered)
        val requests = read(c, "requests"); requests.remove(id); store(c, "requests", requests)
        ReminderDiagnostics.record(c, "snooze_scheduled", id, item.getLong("at"))
        schedule(c, item)
    }
    @Synchronized fun restore(c: Context) {
        createChannel(c)
        val items = read(c, "items")
        for (id in items.keys()) {
            val item = items.getJSONObject(id)
            if (item.optLong("at") > System.currentTimeMillis()) schedule(c, item)
            else if (!read(c, "delivered").has(id) && id != ReminderDiagnostics.TIMED_TEST) show(c, JSONObject(item.toString()).put("alarm", false))
        }
        SyncJobService.configure(c, c.getSharedPreferences("xingji_device", Context.MODE_PRIVATE).getBoolean("background", false))
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val at = intent.getLongExtra("at", 0)
        ReminderDiagnostics.record(context, "receiver_received", id, at)
        try { Reminders.fire(context, id, at) } catch (e: Exception) { ReminderDiagnostics.record(context, "receiver_failed", id, at, error = e) }
    }
}

class RestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ReminderDiagnostics.record(context, "restore_received", detail = intent.action.orEmpty())
        try { Reminders.restore(context) } catch (e: Exception) { ReminderDiagnostics.record(context, "restore_failed", error = e) }
    }
}
