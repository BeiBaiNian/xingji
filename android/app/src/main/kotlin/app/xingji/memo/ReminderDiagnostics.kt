package app.xingji.memo

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.TimeZone

/** Bounded device-local receipts. Never accept titles, bodies, URIs or exception messages. */
object ReminderDiagnostics {
    const val TIMED_TEST = "timed-test"
    fun reference(id: String): String = MessageDigest.getInstance("SHA-256")
        .digest(id.toByteArray()).take(6).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun prefs(c: Context) = c.getSharedPreferences("xingji_reminder_diagnostics", Context.MODE_PRIVATE)
    @Synchronized fun record(c: Context, stage: String, id: String = "", at: Long = 0,
                             detail: String = "", error: Throwable? = null) {
        val now = System.currentTimeMillis()
        val entry = JSONObject().put("time", now).put("stage", stage)
        if (id.isNotEmpty()) entry.put("ref", reference(id))
        if (at != 0L) entry.put("plannedAt", at)
        if (detail.isNotEmpty()) entry.put("detail", detail)
        error?.let { entry.put("error", it.javaClass.simpleName) }
        val saved = JSONArray(prefs(c).getString("events", "[]"))
        val bounded = JSONArray()
        for (i in maxOf(0, saved.length() - 199) until saved.length()) bounded.put(saved.get(i))
        bounded.put(entry)
        val edit = prefs(c).edit().putString("events", bounded.toString())
        if (id == TIMED_TEST) {
            val test = if (stage == "test_scheduled" || stage == "snooze_scheduled") JSONObject().put("at", at)
                else JSONObject(prefs(c).getString("test", "{}"))
            test.put("stage", stage).put("updatedAt", now)
            if (stage == "schedule_submitted" || stage == "registration_failed") test.put("mode", detail)
            if (stage == "receiver_received") test.put("receivedAt", now)
            if (stage == "reminder_route") test.put("route", detail)
            if (stage == "clock_reminder_sent") test.put("clockRequestedAt", now).remove("clockReason")
            if (stage == "clock_reminder_failed") test.put("clockReason", detail)
            if (stage == "playback_started") { test.put("startedAt", now); test.remove("stoppedAt"); test.remove("reason") }
            if (stage == "stopped") test.put("stoppedAt", now).put("reason", detail)
            error?.let { test.put("error", it.javaClass.simpleName) }
            edit.putString("test", test.toString())
        }
        edit.commit()
        Log.i("XingJiAlarm", entry.toString())
    }
    @Synchronized fun test(c: Context): Map<String, Any> {
        val value = JSONObject(prefs(c).getString("test", "{}"))
        return value.keys().asSequence().associateWith { value.get(it) }
    }
    fun export(c: Context): String {
        val saved = JSONArray(prefs(c).getString("events", "[]"))
        val recent = JSONArray()
        for (i in maxOf(0, saved.length() - 10) until saved.length()) recent.put(saved.get(i))
        val info = c.packageManager.getPackageInfo(c.packageName, 0)
        @Suppress("DEPRECATION")
        val build = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        return JSONObject().put("exportedAt", System.currentTimeMillis())
            .put("version", info.versionName).put("build", build)
            .put("sdk", Build.VERSION.SDK_INT).put("android", Build.VERSION.RELEASE)
            .put("osBuild", Build.DISPLAY).put("timezone", TimeZone.getDefault().id)
            .put("manufacturer", Build.MANUFACTURER).put("model", Build.MODEL)
            .put("state", JSONObject(Reminders.state(c).filterKeys { it != "delivered" && it != "systemClockTest" }))
            .put("systemClockTest", SystemClockTest.diagnostics(c))
            .put("eventLimit", 10).put("events", recent).toString(2)
    }
}
