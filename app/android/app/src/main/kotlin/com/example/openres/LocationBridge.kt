package com.example.openres

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.common.api.ResolvableApiException
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import com.google.android.gms.location.DeviceOrientationListener
import com.google.android.gms.location.DeviceOrientationRequest
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.LocationSettingsRequest
import com.google.android.gms.location.Priority
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.sqrt

/**
 * Best-possible location for the map (owner 2026-10-24), the way Google Maps gets it:
 * - "openres/location": Fused Location Provider (GPS + Wi-Fi + cell + sensors), high accuracy,
 *   a fix every second, without waiting for an "accurate" first fix, with speed/bearing accuracy.
 * - "openres/heading": Fused Orientation Provider (gyro + accelerometer + magnetometer, bias and
 *   drift corrected, true north), falling back to the rotation-vector sensor.
 * - "openres/motion": whether the phone is moving (accelerometer), so the filter can hold the
 *   position still while standing.
 * - "openres/activity" (optional, needs the "physical activity" permission): still / walking /
 *   running / bicycle / vehicle from Google's Activity Recognition, to tune the filter.
 * - "openres/location_ctl": checkSettings (Google's "turn on Location Accuracy" dialog),
 *   playServices, activityPermission (asks for it).
 * The location interval follows the app's 1-10 s GPS refresh setting (battery).
 */
class LocationBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val ctx: Context = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())

    init {
        EventChannel(messenger, "openres/location").setStreamHandler(LocationStream())
        EventChannel(messenger, "openres/heading").setStreamHandler(HeadingStream())
        EventChannel(messenger, "openres/motion").setStreamHandler(MotionStream())
        EventChannel(messenger, "openres/activity").setStreamHandler(ActivityStream())
        MethodChannel(messenger, "openres/location_ctl").setMethodCallHandler { call, result ->
            when (call.method) {
                "playServices" -> result.success(playServices())
                "checkSettings" -> checkSettings(result)
                "activityPermission" -> activityPermission(call.argument<Boolean>("ask") == true, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun playServices() =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(ctx) == ConnectionResult.SUCCESS

    private fun request(intervalMs: Long = 1000): LocationRequest =
        LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMs)
            .setMinUpdateIntervalMillis(maxOf(500L, intervalMs / 2))
            .setMaxUpdateDelayMillis(0)              // deliver at once, never batched
            .setWaitForAccurateLocation(false)       // no stall at the start; the Dart filter weighs fixes
            .build()

    /** "ok", "resolving" (Google's dialog is showing) or "unavailable". */
    private fun checkSettings(result: MethodChannel.Result) {
        if (!playServices()) { result.success("unavailable"); return }
        val req = LocationSettingsRequest.Builder().addLocationRequest(request()).setAlwaysShow(true).build()
        LocationServices.getSettingsClient(activity).checkLocationSettings(req)
            .addOnSuccessListener { result.success("ok") }
            .addOnFailureListener { e ->
                if (e is ResolvableApiException) {
                    try {
                        e.startResolutionForResult(activity, 7311)
                        result.success("resolving")
                    } catch (_: Exception) { result.success("unavailable") }
                } else result.success("unavailable")
            }
    }

    private inner class LocationStream : EventChannel.StreamHandler {
        private var cb: LocationCallback? = null

        @SuppressLint("MissingPermission")    // Dart asks for the permission before listening
        override fun onListen(args: Any?, sink: EventChannel.EventSink) {
            if (!playServices()) { sink.error("no_play_services", "Google Play services missing", null); return }
            val client = LocationServices.getFusedLocationProviderClient(ctx)
            cb = object : LocationCallback() {
                override fun onLocationResult(r: LocationResult) {
                    for (l in r.locations) sink.success(toMap(l))
                }
            }
            try {
                val ms = ((args as? Map<*, *>)?.get("interval") as? Number)?.toLong() ?: 1000L
                client.requestLocationUpdates(request(ms.coerceIn(1000L, 10_000L)), cb!!, Looper.getMainLooper())
                client.lastLocation.addOnSuccessListener { l -> if (l != null) sink.success(toMap(l) + ("last" to true)) }
            } catch (e: SecurityException) {
                sink.error("permission", e.message, null)
            }
        }

        override fun onCancel(args: Any?) {
            cb?.let { LocationServices.getFusedLocationProviderClient(ctx).removeLocationUpdates(it) }
            cb = null
        }
    }

    private fun toMap(l: Location): Map<String, Any?> {
        val o = HashMap<String, Any?>()
        o["lat"] = l.latitude
        o["lng"] = l.longitude
        o["acc"] = if (l.hasAccuracy()) l.accuracy.toDouble() else 9999.0
        o["speed"] = if (l.hasSpeed()) l.speed.toDouble() else null
        o["bearing"] = if (l.hasBearing()) l.bearing.toDouble() else null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            o["speedAcc"] = if (l.hasSpeedAccuracy()) l.speedAccuracyMetersPerSecond.toDouble() else null
            o["bearingAcc"] = if (l.hasBearingAccuracy()) l.bearingAccuracyDegrees.toDouble() else null
        }
        o["time"] = l.time
        // age of the fix in ms (the clock is monotonic, so it's right even if the phone's clock isn't)
        o["age"] = (android.os.SystemClock.elapsedRealtimeNanos() - l.elapsedRealtimeNanos) / 1_000_000
        o["mock"] = if (Build.VERSION.SDK_INT >= 31) l.isMock else @Suppress("DEPRECATION") l.isFromMockProvider
        o["provider"] = l.provider
        return o
    }

    private inner class HeadingStream : EventChannel.StreamHandler {
        private var fop: DeviceOrientationListener? = null
        private var sensor: SensorEventListener? = null
        private val exec = Executors.newSingleThreadExecutor()
        private var lastSent = 0L

        override fun onListen(args: Any?, sink: EventChannel.EventSink) {
            fun send(deg: Double, err: Double) {
                val now = System.currentTimeMillis()
                if (now - lastSent < 50) return          // 20 per second is plenty for the marker
                lastSent = now
                main.post { sink.success(mapOf("heading" to deg, "err" to err)) }
            }
            if (playServices()) {
                try {
                    val l = DeviceOrientationListener { o ->
                        send(o.headingDegrees.toDouble(),
                            if (o.hasConservativeHeadingErrorDegrees()) o.conservativeHeadingErrorDegrees.toDouble()
                            else o.headingErrorDegrees.toDouble())
                    }
                    LocationServices.getFusedOrientationProviderClient(ctx).requestOrientationUpdates(
                        DeviceOrientationRequest.Builder(DeviceOrientationRequest.OUTPUT_PERIOD_DEFAULT).build(), exec, l)
                        .addOnFailureListener { startSensor(::send) }
                    fop = l
                    return
                } catch (_: Exception) { }
            }
            startSensor(::send)
        }

        private fun startSensor(send: (Double, Double) -> Unit) {
            val sm = ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager
            val rv = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: return
            val rot = FloatArray(9)
            val ori = FloatArray(3)
            sensor = object : SensorEventListener {
                override fun onSensorChanged(e: SensorEvent) {
                    SensorManager.getRotationMatrixFromVector(rot, e.values)
                    SensorManager.getOrientation(rot, ori)
                    send((Math.toDegrees(ori[0].toDouble()) + 360) % 360, 30.0)   // magnetic north
                }
                override fun onAccuracyChanged(s: Sensor?, a: Int) {}
            }
            sm.registerListener(sensor, rv, SensorManager.SENSOR_DELAY_UI)
        }

        override fun onCancel(args: Any?) {
            fop?.let { LocationServices.getFusedOrientationProviderClient(ctx).removeOrientationUpdates(it) }
            fop = null
            sensor?.let { (ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager).unregisterListener(it) }
            sensor = null
        }
    }

    private val activityPermission =
        if (Build.VERSION.SDK_INT >= 29) Manifest.permission.ACTIVITY_RECOGNITION
        else "com.google.android.gms.permission.ACTIVITY_RECOGNITION"

    private fun hasActivityPermission() =
        ContextCompat.checkSelfPermission(ctx, activityPermission) == PackageManager.PERMISSION_GRANTED

    private var pendingPerm: MethodChannel.Result? = null

    /** true when granted; with ask=true shows Android's permission dialog first. */
    private fun activityPermission(ask: Boolean, result: MethodChannel.Result) {
        if (hasActivityPermission() || !ask || Build.VERSION.SDK_INT < 29) {
            result.success(hasActivityPermission()); return
        }
        pendingPerm?.success(false)
        pendingPerm = result
        ActivityCompat.requestPermissions(activity, arrayOf(activityPermission), PERM_CODE)
    }

    /** From MainActivity.onRequestPermissionsResult. */
    fun onPermissionResult(code: Int) {
        if (code != PERM_CODE) return
        pendingPerm?.success(hasActivityPermission())
        pendingPerm = null
    }

    private inner class ActivityStream : EventChannel.StreamHandler {
        private var receiver: BroadcastReceiver? = null
        private var pi: PendingIntent? = null

        @SuppressLint("MissingPermission")
        override fun onListen(args: Any?, sink: EventChannel.EventSink) {
            if (!playServices() || !hasActivityPermission()) { sink.error("permission", "no activity permission", null); return }
            val action = ctx.packageName + ".ACTIVITY_TRANSITION"
            receiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    if (!ActivityTransitionResult.hasResult(i)) return
                    val e = ActivityTransitionResult.extractResult(i)?.transitionEvents?.lastOrNull() ?: return
                    if (e.transitionType != ActivityTransition.ACTIVITY_TRANSITION_ENTER) return
                    sink.success(when (e.activityType) {
                        DetectedActivity.STILL -> "still"
                        DetectedActivity.WALKING, DetectedActivity.ON_FOOT -> "walking"
                        DetectedActivity.RUNNING -> "running"
                        DetectedActivity.ON_BICYCLE -> "bicycle"
                        DetectedActivity.IN_VEHICLE -> "vehicle"
                        else -> "unknown"
                    })
                }
            }
            ContextCompat.registerReceiver(ctx, receiver, IntentFilter(action), ContextCompat.RECEIVER_EXPORTED)
            pi = PendingIntent.getBroadcast(ctx, 7312, Intent(action).setPackage(ctx.packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0))
            val types = listOf(DetectedActivity.STILL, DetectedActivity.WALKING, DetectedActivity.RUNNING,
                DetectedActivity.ON_BICYCLE, DetectedActivity.IN_VEHICLE)
            val req = ActivityTransitionRequest(types.map {
                ActivityTransition.Builder().setActivityType(it)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER).build()
            })
            try {
                ActivityRecognition.getClient(ctx).requestActivityTransitionUpdates(req, pi!!)
                    .addOnFailureListener { e -> sink.error("unavailable", e.message, null) }
            } catch (e: SecurityException) {
                sink.error("permission", e.message, null)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCancel(args: Any?) {
            try { pi?.let { ActivityRecognition.getClient(ctx).removeActivityTransitionUpdates(it) } } catch (_: Exception) {}
            try { receiver?.let { ctx.unregisterReceiver(it) } } catch (_: Exception) {}
            receiver = null; pi = null
        }
    }

    companion object { const val PERM_CODE = 7313 }

    /** Moving or not, from the spread of the acceleration over the last second (hysteresis). */
    private inner class MotionStream : EventChannel.StreamHandler {
        private var listener: SensorEventListener? = null

        override fun onListen(args: Any?, sink: EventChannel.EventSink) {
            val sm = ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager
            val acc = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return
            var n = 0; var sum = 0.0; var sum2 = 0.0; var start = 0L
            var moving: Boolean? = null
            listener = object : SensorEventListener {
                override fun onSensorChanged(e: SensorEvent) {
                    val m = sqrt((e.values[0] * e.values[0] + e.values[1] * e.values[1] + e.values[2] * e.values[2]).toDouble())
                    if (start == 0L) start = e.timestamp
                    n++; sum += m; sum2 += m * m
                    if (e.timestamp - start >= 1_000_000_000L) {
                        val sd = sqrt(maxOf(0.0, sum2 / n - (sum / n) * (sum / n)))
                        // a phone lying or held still: < 0.12 m/s²; walking or driving: well above
                        val now = if (moving == true) sd > 0.08 else sd > 0.18
                        if (now != moving) { moving = now; sink.success(now) }
                        n = 0; sum = 0.0; sum2 = 0.0; start = e.timestamp
                    }
                }
                override fun onAccuracyChanged(s: Sensor?, a: Int) {}
            }
            sm.registerListener(listener, acc, SensorManager.SENSOR_DELAY_GAME)
        }

        override fun onCancel(args: Any?) {
            listener?.let { (ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager).unregisterListener(it) }
            listener = null
        }
    }
}
