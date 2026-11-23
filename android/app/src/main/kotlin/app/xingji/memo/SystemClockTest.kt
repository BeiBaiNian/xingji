package app.xingji.memo

import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.PowerManager
import android.provider.AlarmClock
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** An explicit foreground handoff experiment, independent of real memo scheduling. */
object SystemClockTest {
    private const val LENGTH = 10
    private val scenarios = setOf("screen_on", "screen_off", "other_app", "swiped_away")
    private val outcomes = setOf("rang", "notification_only", "silent", "not_completed")
    private fun prefs(c: Context) = c.getSharedPreferences("xingji_clock_test", Context.MODE_PRIVATE)
    private fun read(c: Context) = JSONObject(prefs(c).getString("latest", "{}") ?: "{}")
    private fun save(c: Context, value: JSONObject) {
        check(prefs(c).edit().putString("latest", value.toString()).commit())
    }
    private fun device(c: Context) = JSONObject()
        .put("interactive", c.getSystemService(PowerManager::class.java).isInteractive)
        .put("keyguardLocked", c.getSystemService(KeyguardManager::class.java).isKeyguardLocked)
        .put("alarmVolume", c.getSystemService(AudioManager::class.java).getStreamVolume(AudioManager.STREAM_ALARM))
        .put("musicVolume", c.getSystemService(AudioManager::class.java).getStreamVolume(AudioManager.STREAM_MUSIC))
        .put("ringerMode", c.getSystemService(AudioManager::class.java).ringerMode)
        .put("interruptionFilter", c.getSystemService(NotificationManager::class.java).currentInterruptionFilter)

    /** Only primitives cross the Flutter codec; full, bounded metadata stays in the export. */
    fun state(c: Context): Map<String, Any> {
        val value = read(c)
        return listOf("id", "requestedAt", "scenario", "status", "error", "userResult", "reportedAt")
            .filter { value.has(it) }.associateWith { value.get(it) }
    }
    fun diagnostics(c: Context) = read(c)

    fun start(c: Context, activity: Activity?, scenario: String): Map<String, Any> {
        require(scenario in scenarios)
        val previous = read(c)
        val now = System.currentTimeMillis()
        // Repeated taps must not create overlapping timers or overwrite the pending receipt.
        if (previous.optString("status") == "request_sent" &&
            now - previous.optLong("requestedAt") in 0 until LENGTH * 1000L) return state(c)
        val id = UUID.randomUUID().toString()
        val value = JSONObject().put("id", id).put("ref", ReminderDiagnostics.reference(id))
            .put("requestedAt", now).put("scenario", scenario)
            .put("action", AlarmClock.ACTION_SET_TIMER).put("seconds", LENGTH).put("skipUi", true)
            .put("deviceAtRequest", device(c)).put("status", "requesting")
            .put("playbackReceipt", "unavailable")
        save(c, value)
        ReminderDiagnostics.record(c, "clock_test_requested", id, detail = "seconds=10;scenario=$scenario")
        fun failed(status: String, error: Exception? = null): Map<String, Any> {
            value.put("status", status)
            error?.let { value.put("error", it.javaClass.simpleName) }
            save(c, value)
            ReminderDiagnostics.record(c, status, id, error = error)
            return state(c)
        }
        if (activity == null || activity !== MainActivity.foregroundActivity ||
            activity.isFinishing || activity.isDestroyed) return failed("clock_foreground_required")
        val intent = Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, LENGTH)
            .putExtra(AlarmClock.EXTRA_MESSAGE, "星记 · 10 秒测试")
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        // Query only handlers for this action. A resolver is not evidence of the app eventually chosen.
        try {
            val pm = c.packageManager
            val handlers = pm.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            val packages = handlers.map { it.activityInfo.packageName }.distinct()
            value.put("candidateCount", packages.size)
            value.put("candidates", JSONArray().apply {
                for (name in packages.take(5)) {
                    val info = pm.getPackageInfo(name, 0)
                    put(JSONObject().put("package", name).put("version", info.versionName ?: ""))
                }
            })
            val resolved = pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo
            val known = resolved != null && handlers.any {
                it.activityInfo.packageName == resolved.packageName && it.activityInfo.name == resolved.name
            }
            value.put("resolvedPackage", if (known) resolved!!.packageName else "unknown_or_chooser")
        } catch (e: Exception) {
            value.put("discoveryError", e.javaClass.simpleName)
        }
        // Do not wait here or start a Xingji alarm/service: the clock owns the countdown.
        try {
            activity.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            return failed("clock_handler_missing", e)
        } catch (e: SecurityException) {
            return failed("clock_permission_denied", e)
        } catch (e: Exception) {
            return failed("clock_launch_failed", e)
        }
        value.put("status", "request_sent")
        save(c, value)
        ReminderDiagnostics.record(c, "clock_request_sent", id,
            detail = "playback_unconfirmed;resolved=${value.optString("resolvedPackage", "unknown")}")
        return state(c)
    }

    fun report(c: Context, id: String, outcome: String): Map<String, Any> {
        require(outcome in outcomes)
        val value = read(c)
        require(id.isNotEmpty() && value.optString("id") == id && value.optString("status") == "request_sent")
        value.put("userResult", outcome).put("reportedAt", System.currentTimeMillis())
        value.put("deviceAtReport", device(c))
        save(c, value)
        ReminderDiagnostics.record(c, "clock_user_report", id, detail = outcome)
        return state(c)
    }

    fun lifecycle(c: Context, foreground: Boolean) {
        val value = read(c)
        if (value.optString("status") != "request_sent" ||
            System.currentTimeMillis() - value.optLong("requestedAt") !in 0..120000) return
        val snapshot = device(c)
        ReminderDiagnostics.record(c, if (foreground) "clock_host_resumed" else "clock_host_paused",
            value.getString("id"),
            detail = "interactive=${snapshot.getBoolean("interactive")};locked=${snapshot.getBoolean("keyguardLocked")}")
    }
}
