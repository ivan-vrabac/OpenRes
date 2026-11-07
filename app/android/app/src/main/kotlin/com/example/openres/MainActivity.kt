package com.example.openres

import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Build
import android.util.Log
import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import com.google.android.gms.games.PlayGames
import com.google.android.gms.games.PlayGamesSdk
import com.google.android.gms.games.achievement.Achievement
import com.google.android.gms.games.gamessignin.AuthScope
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
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
}
