package app.xingji.memo

import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    companion object { var foregroundActivity: MainActivity? = null; private set }
    private var bridge: DeviceBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = DeviceBridge(this, flutterEngine.dartExecutor.binaryMessenger, this)
        bridge?.activation = Reminders.consumeActivation(this, intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val event = Reminders.consumeActivation(this, intent)
        if (event.isNotEmpty()) bridge?.event(event)
    }
    override fun onResume() {
        super.onResume()
        foregroundActivity = this
        SystemClockTest.lifecycle(this, true)
        SyncCoordinator.foreground = true
        SyncCoordinator.stopBackground?.invoke()
    }
    override fun onPause() {
        SystemClockTest.lifecycle(this, false)
        if (foregroundActivity === this) foregroundActivity = null
        super.onPause()
    }
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val ring = AlarmPlaybackService.current()
        if (ring != null && AlarmActivity.stopKey(event.keyCode)) {
            if (event.action == KeyEvent.ACTION_DOWN) AlarmPlaybackService.dismiss(ring.token)
            return true
        }
        return super.dispatchKeyEvent(event)
    }
    override fun onStop() {
        SyncCoordinator.foreground = false
        super.onStop()
    }
    @Deprecated("Activity result is delegated to the system document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (bridge?.activityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.close()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
