package app.xingji.memo

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import java.util.concurrent.atomic.AtomicReference

object SyncCoordinator {
    val owner = AtomicReference<String?>(null)
    @Volatile var foreground = false
    var stopBackground: (() -> Unit)? = null
}

class SyncJobService : JobService() {
    private var engine: FlutterEngine? = null
    private var bridge: DeviceBridge? = null
    private val handler = Handler(Looper.getMainLooper())
    companion object {
        private const val JOB = 31026
        fun configure(c: Context, enabled: Boolean) {
            c.getSharedPreferences("xingji_device", Context.MODE_PRIVATE).edit().putBoolean("background", enabled).apply()
            val jobs = c.getSystemService(JobScheduler::class.java)
            if (!enabled) { jobs.cancel(JOB); return }
            if (jobs.getPendingJob(JOB) != null) return
            jobs.schedule(JobInfo.Builder(JOB, ComponentName(c, SyncJobService::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setRequiresBatteryNotLow(true).setPersisted(true)
                .setPeriodic(15 * 60 * 1000L).build())
        }
    }
    override fun onStartJob(params: JobParameters): Boolean {
        if (SyncCoordinator.foreground || SyncCoordinator.owner.get() != null) return false
        return try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val runtime = FlutterEngine(applicationContext)
            engine = runtime
            SyncCoordinator.stopBackground = { cleanup(); jobFinished(params, false) }
            bridge = DeviceBridge(applicationContext, runtime.dartExecutor.binaryMessenger, finished = {
                cleanup()
                jobFinished(params, false)
            })
            runtime.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundSync"))
            handler.postDelayed({ cleanup(); jobFinished(params, false) }, 60000)
            true
        } catch (_: Exception) { cleanup(); false }
    }
    private fun cleanup() {
        SyncCoordinator.stopBackground = null
        handler.removeCallbacksAndMessages(null)
        bridge?.close()
        bridge = null
        engine?.destroy()
        engine = null
    }
    override fun onStopJob(params: JobParameters): Boolean { cleanup(); return true }
    override fun onDestroy() { cleanup(); super.onDestroy() }
}
