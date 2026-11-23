package app.xingji.memo

import android.app.AlarmManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.AlarmClock
import android.provider.Settings
import org.json.JSONObject

/** Date/cancel ownership stays in Xingji until due; only the final one-second timer is external. */
object SystemClockReminders {
    private fun prefs(c: Context) = c.getSharedPreferences("xingji_clock_reminders", Context.MODE_PRIVATE)
    fun backgroundAllowed(c: Context): Boolean = Build.VERSION.SDK_INT < 29 || Settings.canDrawOverlays(c)
    fun available(c: Context): Boolean = try { c.packageManager.queryIntentActivities(
        Intent(AlarmClock.ACTION_SET_TIMER), PackageManager.MATCH_DEFAULT_ONLY).isNotEmpty()
    } catch (_: Exception) { false }
    fun latest(c: Context): Map<String, Any> {
        val value = JSONObject(prefs(c).getString("latest", "{}") ?: "{}")
        return value.keys().asSequence().associateWith { value.get(it) }
    }
    fun usesClock(item: JSONObject): Boolean = item.optBoolean("alarm") &&
        item.optBoolean("systemClock", item.optString("id") !in setOf("test", ReminderDiagnostics.TIMED_TEST))

    /** Main-thread callers only. Persist a claim before crossing processes; never retry an uncertain send. */
    fun dispatch(c: Context, item: JSONObject): Boolean {
        val id = item.getString("id")
        val at = item.getLong("at")
        val key = "$id@$at"
        val receipts = JSONObject(prefs(c).getString("receipts", "{}") ?: "{}")
        val previous = receipts.optJSONObject(key)
        if (previous?.optString("status") in setOf("request_sent", "requesting")) {
            ReminderDiagnostics.record(c, "clock_duplicate_ignored", id, at)
            return previous?.optString("status") == "request_sent"
        }
        val receipt = JSONObject().put("ref", ReminderDiagnostics.reference(id)).put("plannedAt", at)
            .put("attemptedAt", System.currentTimeMillis()).put("seconds", 1)
            .put("playbackReceipt", "unavailable")
        fun save(status: String, reason: String = "", error: Exception? = null) {
            receipt.put("status", status).put("updatedAt", System.currentTimeMillis())
            if (reason.isNotEmpty()) receipt.put("reason", reason)
            error?.let { receipt.put("error", it.javaClass.simpleName) }
            // Reinsertion keeps the oldest receipt eviction independent of JSONObject key order.
            receipts.remove(key)
            receipts.put(key, receipt)
            if (receipts.length() > 1600) {
                val oldest = receipts.keys().asSequence().minByOrNull { receipts.getJSONObject(it).optLong("updatedAt") }
                if (oldest != null) receipts.remove(oldest)
            }
            check(prefs(c).edit().putString("receipts", receipts.toString())
                .putString("latest", receipt.toString()).commit())
            ReminderDiagnostics.record(c, if (status == "request_sent") "clock_reminder_sent" else "clock_reminder_$status",
                id, at, if (reason.isNotEmpty()) reason else "seconds=1;playback_unconfirmed", error)
        }
        if (Build.VERSION.SDK_INT >= 31 && !c.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()) {
            save("failed", "exact_permission_missing")
            return false
        }
        val foreground = MainActivity.foregroundActivity
        if (foreground == null && !backgroundAllowed(c)) {
            save("failed", "background_permission_missing")
            return false
        }
        val intent = Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, 1)
            .putExtra(AlarmClock.EXTRA_MESSAGE, item.optString("title", "星记 · 备忘录提醒").take(120))
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        val handlers = try {
            c.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
        } catch (e: Exception) {
            save("failed", "clock_launch_failed", e)
            return false
        }
        if (handlers.isEmpty()) {
            save("failed", "clock_handler_missing")
            return false
        }
        val resolved = try {
            c.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo
        } catch (e: Exception) {
            save("failed", "clock_launch_failed", e)
            return false
        }
        val known = resolved != null && handlers.any {
            it.activityInfo.packageName == resolved.packageName && it.activityInfo.name == resolved.name
        }
        if (!known && foreground == null) {
            save("failed", "clock_choice_required")
            return false
        }
        receipt.put("resolvedPackage", if (known) resolved!!.packageName else "unknown_or_chooser")
        receipt.put("foreground", foreground != null).put("backgroundAllowed", backgroundAllowed(c))
        save("requesting")
        try {
            if (foreground != null) foreground.startActivity(intent)
            else c.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: ActivityNotFoundException) {
            save("failed", "clock_handler_missing", e)
            return false
        } catch (e: SecurityException) {
            save("failed", "clock_launch_denied", e)
            return false
        } catch (e: Exception) {
            save("failed", "clock_launch_failed", e)
            return false
        }
        // startActivity can be silently blocked by an OEM. This is deliberately NOT a playback receipt.
        save("request_sent")
        return true
    }
}
