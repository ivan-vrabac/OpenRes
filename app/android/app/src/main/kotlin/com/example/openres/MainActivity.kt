package com.example.openres

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.Settings
import android.util.Log
import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import androidx.core.content.FileProvider
import com.google.android.gms.games.PlayGames
import com.google.android.gms.games.PlayGamesSdk
import com.google.android.gms.games.achievement.Achievement
import com.google.android.gms.games.gamessignin.AuthScope
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import java.io.File
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var location: LocationBridge? = null
    private var chat: ChatBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // edge to edge on every Android version (Play: Android 15 does it by default); Flutter pads
        // the UI with the system-bar insets
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        keepUprightOnPhones()
        if (getString(R.string.game_services_project_id).isNotEmpty()) PlayGamesSdk.initialize(this)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        keepUprightOnPhones()                     // a foldable opened or closed
    }

    /** Played upright on phones (owner 2026-10-25); tablets and open foldables turn as they like. */
    private fun keepUprightOnPhones() {
        requestedOrientation = if (resources.configuration.smallestScreenWidthDp < 600)
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        chat?.onIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        Poller.foreground = true
    }

    override fun onPause() {
        Poller.foreground = false
        super.onPause()
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        location?.onPermissionResult(code)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        location = LocationBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        chat = ChatBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        // Settings > Performance > No FPS limit: the screen's fastest mode instead of what Android picks
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "openres/display")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "noFpsLimit" -> result.success(setNoFpsLimit(call.argument<Boolean>("on") == true))
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "openres/integrity")
            .setMethodCallHandler { call, result ->
                val project = call.argument<String>("project")?.toLongOrNull()
                val hash = call.argument<String>("hash")
                if (project == null || hash == null) { result.success(null); return@setMethodCallHandler }
                IntegrityManagerFactory.createStandard(applicationContext)
                    .prepareIntegrityToken(PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(project).build())
                    .addOnSuccessListener { provider ->
                        provider.request(StandardIntegrityTokenRequest.builder().setRequestHash(hash).build())
                            .addOnSuccessListener { result.success(it.token()) }
                            .addOnFailureListener { result.success(null) }
                    }
                    .addOnFailureListener { result.success(null) }
            }
        // Play Games sign-in: a one-time code for our server, or null when the player isn't signed in
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "openres/playgames")
            .setMethodCallHandler { call, result ->
                val games = PlayGames.getGamesSignInClient(this)
                val signedIn = { then: (Boolean) -> Unit ->
                    games.isAuthenticated.addOnCompleteListener { t ->
                        val yes = t.isSuccessful && t.result.isAuthenticated
                        if (yes || call.argument<Boolean>("ask") != true) then(yes)
                        else games.signIn().addOnCompleteListener { s -> then(s.isSuccessful && s.result.isAuthenticated) }
                    }
                }
                when (call.method) {
                    "code" -> signedIn { yes ->
                        val client = call.argument<String>("client")
                        if (!yes || client == null) {
                            Log.i("OpenResGames", "no code: signed in $yes")
                            result.success(null)
                        } else {
                            games.requestServerSideAccess(client, false, listOf(AuthScope.OPEN_ID, AuthScope.EMAIL))
                                .addOnCompleteListener {
                                    if (!it.isSuccessful) Log.w("OpenResGames", "server access failed", it.exception)
                                    result.success(if (it.isSuccessful) it.result.authCode else null)
                                }
                        }
                    }
                    "unlock" -> signedIn { yes ->
                        val names = call.argument<List<String>>("names").orEmpty().toSet()
                        if (!yes) result.success(0) else unlockByName(names) { result.success(it) }
                    }
                    else -> result.notImplemented()
                }
            }
        // In-app updates (owner 2026-10-24): Android's DownloadManager fetches the APK into
        // updateDir, so the download goes on when the player leaves the screen or the app, resumes
        // after a dropped connection and shows a notification; then Dart asks us to install it.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "openres/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateDir" -> result.success(updateDir().absolutePath)
                    "cleanup" -> {
                        // the update is installed: forget its download (removes the file and any
                        // notification Android still shows for it)
                        val current = (call.argument<Number>("build") ?: 0).toLong()
                        val p = prefs()
                        val ed = p.edit()
                        for ((k, v) in p.all) {
                            val b = k.removePrefix("dl_").toLongOrNull() ?: continue
                            if (b <= current && v is Long) { try { dm().remove(v) } catch (_: Exception) {}; ed.remove(k) }
                        }
                        ed.apply()
                        result.success(true)
                    }
                    "download" -> result.success(download(
                        call.argument<String>("url")!!, (call.argument<Number>("build")!!).toLong(),
                        (call.argument<Number>("size") ?: 0).toLong()))
                    "progress" -> result.success(progress((call.argument<Number>("id")!!).toLong()))
                    "known" -> result.success(prefs().getLong("dl_${(call.argument<Number>("build")!!).toLong()}", -1))
                    "cancel" -> {
                        dm().remove((call.argument<Number>("id")!!).toLong())
                        result.success(true)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) result.success("error") else result.success(install(File(path)))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Unlocks the Play Games achievements with these names (no IDs to keep in step); answers how many were new. */
    private fun unlockByName(names: Set<String>, done: (Int) -> Unit) {
        val achievements = PlayGames.getAchievementsClient(this)
        achievements.load(true).addOnCompleteListener { t ->       // from Google: the phone's copy can stay empty
            val list = if (t.isSuccessful) t.result.get() else null
            if (list == null) {
                Log.w("OpenResGames", "achievements did not load", t.exception)
                done(0)
                return@addOnCompleteListener
            }
            var new = 0
            for (a in list) {
                if (a.name in names && a.state != Achievement.STATE_UNLOCKED) {
                    achievements.unlock(a.achievementId)
                    new++
                }
            }
            Log.i("OpenResGames", "achievements: ${list.count} known, ${names.size} earned, $new new")
            list.release()
            done(new)
        }
    }

    /** Asks for the fastest mode at the current resolution (or leaves it to Android); returns its Hz. */
    private fun setNoFpsLimit(on: Boolean): Double {
        @Suppress("DEPRECATION")
        val d = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display!! else windowManager.defaultDisplay
        val now = d.mode
        val best = d.supportedModes
            .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: now
        window.attributes = window.attributes.apply { preferredDisplayModeId = if (on) best.modeId else 0 }
        return best.refreshRate.toDouble()
    }

    private fun updateDir(): File =
        File(getExternalFilesDir(null) ?: filesDir, "updates").apply { mkdirs() }

    private fun dm() = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private fun prefs() = getSharedPreferences("updater", Context.MODE_PRIVATE)

    /** Starts (or finds the running) download of [build]: {"id": n}, or {"error": "space", "free": bytes, "need": bytes}. */
    private fun download(url: String, build: Long, size: Long): Map<String, Any> {
        val file = File(updateDir(), "update-$build.apk")
        val key = "dl_$build"
        val known = prefs().getLong(key, -1)
        if (known >= 0) {
            val st = progress(known)["status"]
            if (st == "running" || st == "pending" || st == "paused" || st == "done") return mapOf("id" to known)
            dm().remove(known)
        }
        if (size > 0 && file.exists() && file.length() == size) return mapOf("id" to -1L)   // already here
        file.delete()
        // the APK plus room for the installer to unpack it
        val free = StatFs(updateDir().absolutePath).availableBytes
        val need = size + maxOf(size, 100L * 1024 * 1024)
        if (size > 0 && free < need) return mapOf("error" to "space", "free" to free, "need" to need)
        val id = dm().enqueue(DownloadManager.Request(Uri.parse(url))
            .setTitle("Update (build $build)")
            .setDescription("Downloading the new version")
            .setMimeType("application/vnd.android.package-archive")
            // only while downloading (owner 2026-10-25: a "completed" notification stayed after updating)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
            .setDestinationUri(Uri.fromFile(file)))
        prefs().edit().putLong(key, id).apply()
        return mapOf("id" to id)
    }

    /** {"status": pending|running|paused|done|failed|gone, "done": bytes, "total": bytes, "reason": n, "path": file}. */
    private fun progress(id: Long): Map<String, Any?> {
        if (id < 0) return mapOf("status" to "done")
        dm().query(DownloadManager.Query().setFilterById(id)).use { c ->
            if (c == null || !c.moveToFirst()) return mapOf("status" to "gone")
            fun col(n: String) = c.getColumnIndex(n)
            val status = when (c.getInt(col(DownloadManager.COLUMN_STATUS))) {
                DownloadManager.STATUS_PENDING -> "pending"
                DownloadManager.STATUS_RUNNING -> "running"
                DownloadManager.STATUS_PAUSED -> "paused"          // waiting for the network: resumes by itself
                DownloadManager.STATUS_SUCCESSFUL -> "done"
                else -> "failed"
            }
            return mapOf("status" to status,
                "done" to c.getLong(col(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                "total" to c.getLong(col(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)),
                "reason" to c.getInt(col(DownloadManager.COLUMN_REASON)))
        }
    }

    /** "started", or "permission" when the user must first allow installs from this app. */
    private fun install(apk: File): String {
        if (!apk.exists()) return "error"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return "permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        })
        return "started"
    }
}
