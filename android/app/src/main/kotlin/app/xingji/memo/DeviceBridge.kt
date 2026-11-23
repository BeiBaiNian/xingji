package app.xingji.memo

import android.Manifest
import android.app.Activity
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.ByteArrayOutputStream
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class DeviceBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    private val activity: Activity? = null,
    private val finished: ((Boolean) -> Unit)? = null,
) {
    private val device = MethodChannel(messenger, "xingji/device")
    private val desktop = MethodChannel(messenger, "xingji/desktop")
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val owner = UUID.randomUUID().toString()
    private val importFolder = File(context.cacheDir, "imports")
    private var pendingFile: MethodChannel.Result? = null
    private var exportBytes: ByteArray? = null
    private var certificate = false
    var activation = ""
    private var initialized = false

    init {
        if (activity != null) executor.execute { BackupImports.recover(importFolder) }
        Reminders.createChannel(context)
        device.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "dataDirectory" -> result.success(File(context.filesDir, "XingJi").apply { mkdirs() }.absolutePath)
                    "protect", "unprotect" -> {
                        val bytes = call.arguments as ByteArray
                        executor.execute {
                            try {
                                val value = secure(bytes, call.method == "protect")
                                main.post { result.success(value) }
                            } catch (_: Exception) {
                                main.post { result.error("secure_storage", "设备凭据无法解锁，请重新输入主密码或连接信息", null) }
                            } finally { bytes.fill(0) }
                        }
                    }
                    "acquireSync" -> result.success(SyncCoordinator.owner.compareAndSet(null, owner))
                    "releaseSync" -> { SyncCoordinator.owner.compareAndSet(owner, null); result.success(null) }
                    "releaseBackupImport" -> {
                        val file = File(call.arguments as String)
                        executor.execute {
                            BackupImports.release(file, owner)
                            main.post { result.success(null) }
                        }
                    }
                    "background" -> { SyncJobService.configure(context, call.argument<Boolean>("enabled") == true); result.success(null) }
                    "backgroundFinished" -> {
                        result.success(null)
                        main.post { finished?.invoke(call.argument<Boolean>("success") == true) }
                    }
                    "pickImage" -> {
                        check(activity != null && pendingFile == null)
                        pendingFile = result
                        val request = PickVisualMediaRequest(PickVisualMedia.ImageOnly)
                        activity.startActivityForResult(PickVisualMedia().createIntent(activity, request), 504)
                    }
                    "pasteImage" -> {
                        check(activity != null && activity.hasWindowFocus())
                        val clipboard = context.getSystemService(ClipboardManager::class.java)
                        val clip = clipboard.primaryClip
                        val uri = (0 until (clip?.itemCount ?: 0)).asSequence()
                            .mapNotNull { clip?.getItemAt(it)?.uri }
                            .firstOrNull { it.scheme == ContentResolver.SCHEME_CONTENT &&
                                (clip?.description?.hasMimeType("image/*") == true ||
                                    context.contentResolver.getType(it)?.startsWith("image/") == true) }
                        if (uri == null) result.success(null) else readImage(uri, result)
                    }
                    "pickFile", "saveBackup" -> {
                        if (activity == null || pendingFile != null) throw IllegalStateException("文件选择器不可用")
                        pendingFile = result
                        if (call.method == "pickFile") {
                            certificate = call.argument<Boolean>("certificate") == true
                            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            }, 501)
                        } else {
                            exportBytes = call.argument<ByteArray>("bytes")!!
                            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/octet-stream"
                                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
                            }, 502)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                if (pendingFile === result) {
                    pendingFile = null
                    exportBytes?.fill(0)
                    exportBytes = null
                }
                result.error("device", "设备操作未完成，请重试", null)
            }
        }
        desktop.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "initialize" -> {
                        initialized = true
                        val state = Reminders.state(context).toMutableMap()
                        state["activation"] = activation
                        activation = ""
                        result.success(state)
                    }
                    "notificationState" -> result.success(Reminders.state(context))
                    "clockBackgroundSettings" -> {
                        check(activity != null)
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:${context.packageName}")))
                        result.success(null)
                    }
                    "testSystemClock" -> result.success(SystemClockTest.start(context, activity,
                        call.argument<String>("scenario") ?: "screen_on"))
                    "reportSystemClockTest" -> result.success(SystemClockTest.report(context,
                        call.argument<String>("id") ?: "", call.argument<String>("outcome") ?: ""))
                    "scheduleTimedTest" -> result.success(Reminders.scheduleTest(context))
                    "cancelTimedTest" -> { Reminders.cancelTest(context); result.success(null) }
                    "reminderDiagnostics" -> result.success(ReminderDiagnostics.export(context))
                    "replaceSchedules" -> {
                        val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
                        val remove = call.argument<List<String>>("removeIds") ?: emptyList()
                        Reminders.replace(context, items, remove, call.argument<List<String>>("activeIds") ?: emptyList(), call.argument<Boolean>("alarmMode") == true)
                        result.success(null)
                    }
                    "showNotification" -> { Reminders.show(context, JSONObject(call.arguments as Map<*, *>)); result.success(null) }
                    "requestNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 && activity != null &&
                            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 503)
                        }
                        result.success(null)
                    }
                    "notificationSettings" -> {
                        activity?.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
                        result.success(null)
                    }
                    "screenOnNotificationSettings" -> {
                        context.startActivity(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            .putExtra(Settings.EXTRA_CHANNEL_ID, "xingji_screen_on_reminders")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    "alarmChannelSettings" -> {
                        activity?.startActivity(Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            .putExtra(Settings.EXTRA_CHANNEL_ID, "xingji_alarm_playback"))
                        result.success(null)
                    }
                    "appSettings" -> {
                        activity?.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:${context.packageName}")))
                        result.success(null)
                    }
                    "exactSettings" -> {
                        if (Build.VERSION.SDK_INT >= 31) activity?.startActivity(Intent(
                            Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${context.packageName}")))
                        result.success(null)
                    }
                    "alarmSoundSettings" -> {
                        activity?.startActivity(Intent(Settings.ACTION_SOUND_SETTINGS))
                        result.success(null)
                    }
                    "fullScreenSettings" -> {
                        if (Build.VERSION.SDK_INT >= 34) activity?.startActivity(Intent(
                            Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${context.packageName}")))
                        result.success(null)
                    }
                    "show", "theme", "startup" -> result.success(null)
                    "hide", "exit" -> { activity?.moveTaskToBack(true); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                ReminderDiagnostics.record(context, "bridge_failed", detail = call.method, error = e)
                result.error("notification", "系统提醒操作未完成，请检查权限后重试", null)
            }
        }
    }

    fun event(value: String) {
        if (initialized) desktop.invokeMethod("event", value) else activation = value
    }

    private fun secure(bytes: ByteArray, encrypt: Boolean): ByteArray {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "xingji.device.v1"
        val key = synchronized(SyncCoordinator) {
            if (!store.containsAlias(alias)) {
                if (!encrypt) throw IllegalStateException("Device key missing")
                KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                    init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256).setRandomizedEncryptionRequired(true).build())
                }.generateKey()
            }
            store.getKey(alias, null) as SecretKey
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        if (encrypt) cipher.init(Cipher.ENCRYPT_MODE, key) else {
            require(bytes.size >= 30 && bytes[0] == 1.toByte())
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
        }
        cipher.updateAAD("xingji-device:1".toByteArray(Charsets.UTF_8))
        return if (encrypt) byteArrayOf(1) + cipher.iv + cipher.doFinal(bytes)
            else cipher.doFinal(bytes, 13, bytes.size - 13)
    }

    fun activityResult(code: Int, status: Int, intent: Intent?): Boolean {
        if (code != 501 && code != 502 && code != 504) return false
        val result = pendingFile ?: return true
        pendingFile = null
        val uri = intent?.data
        val bytes = exportBytes
        exportBytes = null
        if (status != Activity.RESULT_OK || uri == null) {
            bytes?.fill(0)
            result.success(if (code == 502) false else null)
            return true
        }
        if (code == 504) {
            readImage(uri, result)
            return true
        }
        val isCertificate = certificate
        executor.execute {
            var temporary: File? = null
            try {
                if (code == 502) {
                    context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes!!) }
                    main.post { result.success(true) }
                } else {
                    val destination = if (isCertificate) {
                        val folder = File(context.filesDir, "certificates").apply { mkdirs() }
                        File(folder, "${UUID.randomUUID()}.pem")
                    } else BackupImports.create(importFolder, owner)
                    temporary = destination
                    context.contentResolver.openInputStream(uri)!!.use { input ->
                        destination.outputStream().use { output ->
                            val buffer = ByteArray(16384)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                require(total <= if (isCertificate) 1024 * 1024 else 80L * 1024 * 1024)
                                output.write(buffer, 0, count)
                            }
                        }
                    }
                    main.post { result.success(destination.absolutePath) }
                    temporary = null
                }
            } catch (_: Exception) {
                temporary?.let { if (isCertificate) it.delete() else BackupImports.release(it, owner) }
                main.post { result.error("file", "文件无法读取或保存，或超过大小限制", null) }
            } finally { bytes?.fill(0) }
        }
        return true
    }

    private fun readImage(uri: Uri, result: MethodChannel.Result) {
        executor.execute {
            try {
                require(uri.scheme == ContentResolver.SCHEME_CONTENT)
                val bytes = context.contentResolver.openInputStream(uri)!!.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(16384)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(output.size() + count <= 32 * 1024 * 1024)
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                main.post { result.success(bytes) }
            } catch (_: Exception) {
                main.post { result.error("image", "图片无法读取，请选择 32 MiB 以内的本机图片", null) }
            }
        }
    }

    fun close() {
        device.setMethodCallHandler(null)
        desktop.setMethodCallHandler(null)
        SyncCoordinator.owner.compareAndSet(owner, null)
        if (activity != null) executor.execute { BackupImports.close(owner) }
        executor.shutdown()
        exportBytes?.fill(0)
    }
}
