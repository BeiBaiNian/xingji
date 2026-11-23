package app.xingji.memo

import android.app.Activity
import android.app.ActivityOptions
import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.Date
import kotlin.math.abs
import kotlin.math.min

/** A native alarm surface; never opens or unlocks the encrypted vault. */
open class AlarmActivity : Activity() {
    companion object {
        var foregroundActivity: AlarmActivity? = null; private set
        fun fullScreenAllowed(c: Context): Boolean = Build.VERSION.SDK_INT < 34 ||
            c.getSystemService(NotificationManager::class.java).canUseFullScreenIntent()
        private fun intent(c: Context, token: String): Intent {
            val full = AlarmPlaybackService.current()?.lockScreen == true ||
                c.getSystemService(KeyguardManager::class.java).isKeyguardLocked
            return Intent(c, if (full) AlarmActivity::class.java else AlarmDialogActivity::class.java)
                .setData(Uri.parse("xingji-alarm-ui://$token")).putExtra("token", token)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        fun pending(c: Context, token: String): PendingIntent {
            val options = if (Build.VERSION.SDK_INT >= 34) ActivityOptions.makeBasic()
                .setPendingIntentCreatorBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
                .toBundle() else null
            return PendingIntent.getActivity(c, 0, intent(c, token),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE, options)
        }
        fun open(activity: Activity, token: String) { activity.startActivity(intent(activity, token)) }
        fun stopKey(code: Int) = code == KeyEvent.KEYCODE_VOLUME_UP ||
            code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_VOLUME_MUTE
    }
    private var token = ""
    private var locked = false
    private val observer: () -> Unit = {
        val current = AlarmPlaybackService.current()
        if (current == null) finish()
        else if (current.token != token) render(Intent(intent).putExtra("token", current.token))
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    override fun onCreate(state: Bundle?) {
        locked = AlarmPlaybackService.current()?.lockScreen == true ||
            getSystemService(KeyguardManager::class.java).isKeyguardLocked ||
            !getSystemService(PowerManager::class.java).isInteractive
        setTheme(if (locked) R.style.AlarmFullTheme else R.style.AlarmDialogTheme)
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true) }
        else window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        setFinishOnTouchOutside(false)
        AlarmPlaybackService.observe(observer)
        render(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A delayed notification click must not replace the current alarm controls.
        if (intent.getStringExtra("token") == AlarmPlaybackService.current()?.token) render(intent)
    }
    override fun onResume() { super.onResume(); foregroundActivity = this }
    override fun onPause() {
        if (foregroundActivity === this) foregroundActivity = null
        super.onPause()
    }

    private fun render(source: Intent) {
        token = source.getStringExtra("token") ?: ""
        val current = AlarmPlaybackService.current()
        if (current == null || current.token != token) { finish(); return }
        ReminderDiagnostics.record(this, "window_shown", detail = if (locked) "lock_screen" else "dialog")
        setIntent(source)
        val ink = Color.parseColor(if (locked) "#EDF6F3" else "#203D35")
        val muted = Color.parseColor(if (locked) "#AAC6C1" else "#60756F")
        val accent = Color.parseColor(if (locked) "#9BDCCB" else "#287F6A")
        val panel = Color.parseColor(if (locked) "#18313B" else "#F5F9F7")
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            setPadding(dp(24), dp(28), dp(24), dp(24))
            background = GradientDrawable().apply { setColor(panel); cornerRadius = dp(24).toFloat() }
        }
        fun label(text: String, size: Float, color: Int, bold: Boolean = false): TextView = TextView(this).apply {
            this.text = text; textSize = size; setTextColor(color); gravity = Gravity.CENTER
            if (bold) typeface = Typeface.DEFAULT_BOLD
        }
        fun space(value: Int) { content.addView(View(this), LinearLayout.LayoutParams(1, dp(value))) }
        content.addView(ImageView(this).apply { setImageResource(R.drawable.ic_notify); setColorFilter(accent) },
            LinearLayout.LayoutParams(dp(40), dp(40)))
        space(10)
        content.addView(label("星记 · 闹铃", 14f, muted))
        space(12)
        content.addView(label(android.text.format.DateFormat.getTimeFormat(this).format(Date(current.startedAt)),
            if (locked) 52f else 40f, ink, true))
        space(12)
        content.addView(label(current.title, 21f, ink, true).apply { maxLines = 3 })
        space(10)
        content.addView(label("关闭铃声后，备忘录仍保留在待办中", 13f, muted))
        space(24)
        val swipe = label("↑\n上滑关闭闹铃", 18f, accent, true).apply {
            gravity = Gravity.CENTER
            background = GradientDrawable().apply { setColor(if (locked) 0x2638B99A else 0x15287F6A); cornerRadius = dp(20).toFloat() }
            isClickable = true
            contentDescription = "上滑关闭闹铃，或双击关闭"
            setOnClickListener { dismiss() }
        }
        var downX = 0f
        var downY = 0f
        var travel = 0f
        swipe.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; downY = event.rawY; travel = 0f
                    view.parent.requestDisallowInterceptTouchEvent(true)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    travel = downY - event.rawY
                    view.translationY = -travel.coerceIn(0f, dp(100).toFloat()) * 0.45f
                    val progress = (travel / dp(72) * 100).toInt().coerceIn(0, 100)
                    swipe.text = if (travel >= dp(72) && travel > abs(event.rawX - downX) * 1.5f) "↑\n松开关闭闹铃" else "↑  $progress%\n上滑关闭闹铃"
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (travel >= dp(72) && travel > abs(event.rawX - downX) * 1.5f) dismiss()
                    view.translationY = 0f; swipe.text = "↑\n上滑关闭闹铃"
                    view.parent.requestDisallowInterceptTouchEvent(false)
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    view.translationY = 0f; swipe.text = "↑\n上滑关闭闹铃"
                    view.parent.requestDisallowInterceptTouchEvent(false)
                    true
                }
                else -> false
            }
        }
        if (locked) {
            content.addView(swipe, LinearLayout.LayoutParams(-1, dp(88)))
            space(16)
        }
        content.addView(Button(this).apply {
            text = "关闭闹铃"; textSize = 17f; isAllCaps = false
            setTextColor(if (locked) Color.parseColor("#143C32") else Color.WHITE)
            background = GradientDrawable().apply { setColor(accent); cornerRadius = dp(16).toFloat() }
            stateListAnimator = null; elevation = 0f
            setOnClickListener { dismiss() }
        }, LinearLayout.LayoutParams(-1, dp(54)))
        content.addView(Button(this).apply {
            text = "10 分钟后再响"; textSize = 15f; isAllCaps = false
            setTextColor(accent); setBackgroundColor(Color.TRANSPARENT)
            stateListAnimator = null; elevation = 0f
            setOnClickListener { AlarmPlaybackService.dismiss(token, true); finish() }
        }, LinearLayout.LayoutParams(-1, dp(52)))
        space(8)
        content.addView(label("音量键或短按电源键也可关闭", 12f, muted))
        val scroll = ScrollView(this).apply { isFillViewport = true; addView(content) }
        setContentView(scroll)
        if (locked) {
            window.setBackgroundDrawableResource(android.R.color.transparent)
            window.setLayout(-1, -1)
            window.statusBarColor = panel; window.navigationBarColor = panel
        } else {
            window.setBackgroundDrawableResource(android.R.color.transparent)
            window.setLayout(min(resources.displayMetrics.widthPixels - dp(32), dp(380)), -2)
        }
    }
    private fun dismiss() { AlarmPlaybackService.dismiss(token); finish() }
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (stopKey(event.keyCode)) {
            if (event.action == KeyEvent.ACTION_DOWN) dismiss()
            return true
        }
        return super.dispatchKeyEvent(event)
    }
    @Deprecated("Back closes this alarm only")
    override fun onBackPressed() = dismiss()
    override fun onDestroy() { AlarmPlaybackService.removeObserver(observer); super.onDestroy() }
}

// Android determines task translucency from the manifest theme before onCreate.
// A separate dialog component keeps the previous app visible behind the popup.
class AlarmDialogActivity : AlarmActivity()
