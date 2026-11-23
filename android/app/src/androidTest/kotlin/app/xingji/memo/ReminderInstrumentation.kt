package app.xingji.memo

import android.app.Activity
import android.app.AlarmManager
import android.app.Instrumentation
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.ActivityNotFoundException
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.AlarmClock
import org.json.JSONArray
import org.json.JSONObject

/** No test components are compiled into the release APK. Emulator fixtures only. */
class ReminderInstrumentation : Instrumentation() {
    private var scenario: String? = null
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        check(arguments?.getString("isolated") == "true" &&
            (Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish")) { "Isolated emulator required" }
        scenario = arguments?.getString("clockScenario")
        check(scenario == null || scenario in setOf("background", "cancelled", "rescheduled"))
        start()
    }
    private fun onMain(work: () -> Unit) {
        var failure: Throwable? = null
        runOnMainSync { try { work() } catch (e: Throwable) { failure = e } }
        failure?.let { throw it }
    }
    private fun waitUntil(label: String, condition: () -> Boolean) {
        val end = System.currentTimeMillis() + 45000
        while (System.currentTimeMillis() < end) {
            var done = false
            onMain { done = condition() }
            if (done) return
            Thread.sleep(100)
        }
        error("Timed out: $label")
    }
    override fun onStart() {
        if (scenario != null) {
            // End instrumentation before delivery so the receiver runs without test foreground privileges.
            val c = targetContext
            val at = System.currentTimeMillis() + 20000
            val id = "clock-background-" + java.util.UUID.randomUUID()
            val row = mapOf<String, Any?>("id" to id, "at" to at, "alarm" to true,
                "systemClock" to true, "title" to "星记 · 后台事项测试")
            onMain {
                Reminders.cancelTest(c)
                Reminders.replace(c, listOf(row), emptyList(), listOf(id), true)
                if (scenario == "cancelled") Reminders.replace(c, emptyList(), listOf(id), emptyList(), true)
                if (scenario == "rescheduled") Reminders.replace(c,
                    listOf(row + ("at" to at + 20000)), emptyList(), listOf(id), true)
            }
            finish(Activity.RESULT_OK, Bundle().apply {
                putString("scenario", scenario)
                putString("ref", ReminderDiagnostics.reference(id))
                putLong("plannedAt", at)
                putLong("rescheduledAt", if (scenario == "rescheduled") at + 20000 else at)
            })
            return
        }
        val result = Bundle()
        val completed = mutableListOf<String>()
        var resultCode = Activity.RESULT_OK
        val c = targetContext
        val p = c.getSharedPreferences("xingji_schedules", Context.MODE_PRIVATE)
        fun data(name: String) = JSONObject(p.getString(name, "{}") ?: "{}")
        fun row(id: String, at: Long) = mapOf<String, Any?>("id" to id, "at" to at,
            "alarm" to true, "systemClock" to false, "title" to "PRIVATE_FIXTURE_TITLE", "body" to "PRIVATE_FIXTURE_BODY")
        fun reset() {
            onMain {
                Reminders.cancelTest(c)
                AlarmPlaybackService.stop(c)
                Reminders.replace(c, emptyList(), emptyList(), emptyList(), false)
            }
            waitUntil("service stopped") { AlarmPlaybackService.current() == null }
            p.edit().clear().commit()
        }
        fun test(name: String, work: () -> Unit) { work(); completed.add(name) }
        try {
            reset()
            onMain {
                c.getSystemService(NotificationManager::class.java).createNotificationChannel(
                    NotificationChannel("xingji_reminders", "fixture ordinary", NotificationManager.IMPORTANCE_NONE))
            }
            test("alarm_clock_registration_and_near_due_sync") {
                val at = System.currentTimeMillis() + 1500
                onMain {
                    Reminders.replace(c, listOf(row("fixture-near", at)), emptyList(), listOf("fixture-near"), true)
                    check(data("registrations").getJSONObject("fixture-near").getString("mode") == "alarm_clock")
                    Reminders.replace(c, emptyList(), emptyList(), listOf("fixture-near"), true)
                    check(data("items").has("fixture-near"))
                    check(c.getSystemService(AlarmManager::class.java).nextAlarmClock?.triggerTime == at)
                }
                reset()
            }
            test("cancelled_rows_are_removed") {
                val at = System.currentTimeMillis() + 300000
                onMain {
                    Reminders.replace(c, listOf(row("fixture-remove", at)), emptyList(), listOf("fixture-remove"), true)
                    Reminders.replace(c, emptyList(), listOf("fixture-remove"), emptyList(), true)
                    check(!data("items").has("fixture-remove"))
                    check(!data("registrations").has("fixture-remove"))
                }
            }
            test("service_request_is_not_delivery_and_stale_trigger_is_ignored") {
                val at = System.currentTimeMillis() - 10
                onMain {
                    Reminders.replace(c, listOf(row("fixture-ring", at)), emptyList(), listOf("fixture-ring"), true)
                    Reminders.fire(c, "fixture-ring", at - 1000)
                    check(!data("requests").has("fixture-ring"))
                    Reminders.fire(c, "fixture-ring", at)
                    check(!data("delivered").has("fixture-ring"))
                }
                waitUntil("real playback acknowledgement") { data("delivered").has("fixture-ring") }
                onMain {
                    Reminders.replace(c, emptyList(), emptyList(), listOf("fixture-ring"), true)
                    check(AlarmPlaybackService.current() != null)
                }
                reset()
            }
            test("timed_test_survives_sync_and_reaches_real_receiver") {
                onMain {
                    // A disabled ordinary channel must not disable the independent alarm channel.
                    check(Reminders.state(c)["allowed"] == false)
                    check(Reminders.state(c)["notificationsAllowed"] == true)
                    Reminders.scheduleTest(c, systemClock = false)
                    Reminders.replace(c, emptyList(), emptyList(), emptyList(), true)
                    check(data("items").has(ReminderDiagnostics.TIMED_TEST))
                    check(!data("delivered").has(ReminderDiagnostics.TIMED_TEST))
                }
                waitUntil("30 second receiver and playback") { ReminderDiagnostics.test(c).containsKey("startedAt") }
                val receipt = ReminderDiagnostics.test(c)
                check(receipt.containsKey("receivedAt"))
                val at = receipt["at"] as Long
                val started = receipt["startedAt"] as Long
                check(started - at in 0..5000)
                result.putLong("plannedAt", at)
                result.putLong("receivedAt", receipt["receivedAt"] as Long)
                result.putLong("startedAt", started)
            }
            var oldToken = ""
            test("native_ten_minute_snooze") {
                onMain {
                    oldToken = AlarmPlaybackService.current()!!.token
                    check(AlarmPlaybackService.dismiss(oldToken, true))
                    val at = data("snoozes").getJSONObject(ReminderDiagnostics.TIMED_TEST).getLong("at")
                    check(at - System.currentTimeMillis() in 590000..600000)
                    Reminders.replace(c, emptyList(), emptyList(), emptyList(), true)
                    check(data("items").getJSONObject(ReminderDiagnostics.TIMED_TEST).getLong("at") == at)
                }
                waitUntil("snooze stopped service") { AlarmPlaybackService.current() == null }
            }
            test("old_tokens_cannot_stop_new_ring") {
                onMain { Reminders.show(c, JSONObject().put("id", "test").put("alarm", true)) }
                waitUntil("preview ring") { AlarmPlaybackService.current() != null }
                onMain {
                    check(!AlarmPlaybackService.dismiss(oldToken))
                    check(AlarmPlaybackService.current() != null)
                    AlarmPlaybackService.dismiss(AlarmPlaybackService.current()!!.token)
                }
                reset()
            }
            // Intercept just the outgoing clock activity. This verifies the contract, not OEM sound.
            val host = startActivitySync(Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            waitUntil("foreground test host") { MainActivity.foregroundActivity === host }
            var captured: Intent? = null
            var launches = 0
            var launchFailure = ""
            val monitor = object : ActivityMonitor() {
                override fun onStartActivity(intent: Intent): ActivityResult? {
                    if (intent.action != AlarmClock.ACTION_SET_TIMER) return null
                    captured = Intent(intent)
                    launches++
                    if (launchFailure == "missing") throw ActivityNotFoundException("PRIVATE_FIXTURE_ERROR")
                    if (launchFailure == "denied") throw SecurityException("PRIVATE_FIXTURE_ERROR")
                    return ActivityResult(Activity.RESULT_OK, null)
                }
            }
            addMonitor(monitor)
            val clockPrefs = c.getSharedPreferences("xingji_clock_test", Context.MODE_PRIVATE)
            try {
                test("clock_handoff_uses_standard_ten_second_intent_without_memo_changes") {
                    clockPrefs.edit().clear().commit()
                    val before = data("items").toString()
                    onMain {
                        val receipt = SystemClockTest.start(c, host, "screen_off")
                        check(receipt["status"] == "request_sent")
                        check(!receipt.containsKey("startedAt") && !receipt.containsKey("userResult"))
                        val sent = captured!!
                        check(sent.action == AlarmClock.ACTION_SET_TIMER)
                        check(sent.getIntExtra(AlarmClock.EXTRA_LENGTH, -1) == 10)
                        check(sent.getBooleanExtra(AlarmClock.EXTRA_SKIP_UI, false))
                        check(sent.component == null && sent.`package` == null)
                        check(!sent.getStringExtra(AlarmClock.EXTRA_MESSAGE)!!.contains("PRIVATE_FIXTURE"))
                        check(c.checkSelfPermission("com.android.alarm.permission.SET_ALARM") == 0)
                        check(SystemClockTest.start(c, host, "other_app")["id"] == receipt["id"])
                        check(launches == 1)
                        check(data("items").toString() == before && AlarmPlaybackService.current() == null)
                    }
                }
                test("clock_feedback_is_manual_and_rejects_stale_sessions") {
                    val id = SystemClockTest.state(c)["id"] as String
                    check(runCatching { SystemClockTest.report(c, "old-session", "rang") }.isFailure)
                    check(runCatching { SystemClockTest.report(c, id, "automatic_success") }.isFailure)
                    check(SystemClockTest.report(c, id, "silent")["userResult"] == "silent")
                    check(SystemClockTest.diagnostics(c).getString("playbackReceipt") == "unavailable")
                }
                test("clock_missing_handler_and_permission_failures_are_not_success") {
                    for ((failure, status) in listOf("missing" to "clock_handler_missing", "denied" to "clock_permission_denied")) {
                        clockPrefs.edit().clear().commit()
                        launchFailure = failure
                        onMain { check(SystemClockTest.start(c, host, "screen_on")["status"] == status) }
                        check(!SystemClockTest.state(c).containsKey("userResult"))
                    }
                    clockPrefs.edit().clear().commit()
                    onMain { check(SystemClockTest.start(c, null, "screen_on")["status"] == "clock_foreground_required") }
                }
                uiAutomation.executeShellCommand("input keyevent 223").close()
                waitUntil("screen off before clock route") { !c.getSystemService(PowerManager::class.java).isInteractive }
                test("formal_clock_due_handoff_is_one_second_and_idempotent") {
                    launchFailure = ""
                    val before = launches
                    val at = System.currentTimeMillis() - 10
                    onMain {
                        Reminders.replace(c, listOf(row("formal-clock", at) + mapOf("systemClock" to true,
                            "title" to "星记 · 有一项备忘录到期")), emptyList(), listOf("formal-clock"), true)
                        Reminders.fire(c, "formal-clock", at)
                        check(launches == before + 1)
                        check(captured!!.getIntExtra(AlarmClock.EXTRA_LENGTH, -1) == 1)
                        check(captured!!.getBooleanExtra(AlarmClock.EXTRA_SKIP_UI, false))
                        check(captured!!.getStringExtra(AlarmClock.EXTRA_MESSAGE) == "星记 · 有一项备忘录到期")
                        check(AlarmPlaybackService.current() == null)
                        check(SystemClockReminders.latest(c)["status"] == "request_sent")
                        check(data("delivered").has("formal-clock"))
                        Reminders.fire(c, "formal-clock", at)
                        check(launches == before + 1)
                    }
                }
                test("formal_clock_retime_cancel_and_foreground_sync_do_not_leave_old_timers") {
                    val before = launches
                    val at = System.currentTimeMillis() + 60000
                    onMain {
                        Reminders.replace(c, listOf(row("formal-change", at) + ("systemClock" to true)),
                            emptyList(), listOf("formal-change"), true)
                        Reminders.replace(c, listOf(row("formal-change", at + 60000) + ("systemClock" to true)),
                            emptyList(), listOf("formal-change"), true)
                        Reminders.fire(c, "formal-change", at)
                        check(launches == before)
                        check(data("items").getJSONObject("formal-change").getLong("at") == at + 60000)
                        Reminders.replace(c, emptyList(), listOf("formal-change"), emptyList(), true)
                        Reminders.fire(c, "formal-change", at + 60000)
                        check(launches == before)
                        check(!data("items").has("formal-change"))
                    }
                }
                test("formal_clock_rejected_launch_keeps_failed_receipt_and_never_claims_sound") {
                    val at = System.currentTimeMillis() - 10
                    launchFailure = "denied"
                    onMain {
                        Reminders.replace(c, listOf(row("formal-denied", at) + ("systemClock" to true)),
                            emptyList(), listOf("formal-denied"), true)
                        Reminders.fire(c, "formal-denied", at)
                        check(SystemClockReminders.latest(c)["status"] == "failed")
                        check(SystemClockReminders.latest(c)["reason"] == "clock_launch_denied")
                        check(!SystemClockReminders.latest(c).containsKey("startedAt"))
                        check(AlarmPlaybackService.current() == null)
                    }
                    launchFailure = ""
                }
                uiAutomation.executeShellCommand("input keyevent 224").close()
                waitUntil("screen on before notification route") { c.getSystemService(PowerManager::class.java).isInteractive }
                test("screen_on_reminder_posts_one_notification_without_clock_or_player") {
                    val before = launches
                    val at = System.currentTimeMillis() - 10
                    onMain {
                        Reminders.replace(c, listOf(row("formal-screen-on", at) + ("systemClock" to true)),
                            emptyList(), listOf("formal-screen-on"), true)
                        Reminders.fire(c, "formal-screen-on", at)
                        Reminders.fire(c, "formal-screen-on", at)
                        check(launches == before && AlarmPlaybackService.current() == null)
                    }
                    waitUntil("screen on notification posted") {
                        c.getSystemService(NotificationManager::class.java).activeNotifications.any { it.tag == "formal-screen-on" }
                    }
                    onMain {
                        val notification = c.getSystemService(NotificationManager::class.java).activeNotifications
                            .single { it.tag == "formal-screen-on" }.notification
                        check(notification.channelId == "xingji_screen_on_reminders")
                        check(notification.fullScreenIntent == null)
                        check(notification.flags and android.app.Notification.FLAG_INSISTENT == 0)
                        check(notification.flags and android.app.Notification.FLAG_ONLY_ALERT_ONCE != 0)
                        val channel = c.getSystemService(NotificationManager::class.java).getNotificationChannel(notification.channelId)
                        check(channel.importance == NotificationManager.IMPORTANCE_HIGH && channel.sound != null)
                        check(data("delivered").has("formal-screen-on"))
                    }
                }
            } finally { removeMonitor(monitor) }
            test("diagnostics_export_only_latest_ten_events_and_keep_private_summary") {
                repeat(205) { ReminderDiagnostics.record(c, "fixture_event", "non-business-fixture", detail = "$it") }
                val report = JSONObject(ReminderDiagnostics.export(c))
                val events = report.getJSONArray("events")
                check(events.length() == 10 && report.getInt("eventLimit") == 10)
                check(events.getJSONObject(0).getString("detail") == "195")
                check(events.getJSONObject(9).getString("detail") == "204")
                check(JSONArray(c.getSharedPreferences("xingji_reminder_diagnostics", Context.MODE_PRIVATE)
                    .getString("events", "[]")).length() == 200)
                check(report.getJSONObject("systemClockTest").getString("status") == "clock_foreground_required")
                check(report.has("version") && report.has("osBuild"))
                check(!report.toString().contains("PRIVATE_FIXTURE"))
                check(!report.getJSONObject("state").has("delivered"))
            }
            result.putString("passed", completed.joinToString(","))
            result.putInt("count", completed.size)
        } catch (e: Throwable) {
            result.putString("passed", completed.joinToString(","))
            result.putString("failure", e.stackTraceToString())
            resultCode = Activity.RESULT_CANCELED
        } finally { reset() }
        finish(resultCode, result)
    }
}
