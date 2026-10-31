import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Push notifications need this private file; without it the app builds and simply has none.
if (file("google-services.json").exists()) apply(plugin = "com.google.gms.google-services")

// Branding: read the same values the Dart code sees. Flutter passes every
// --dart-define / --dart-define-from-file entry to Gradle as base64 in "dart-defines".
val dartDefines: Map<String, String> = (project.findProperty("dart-defines") as String?)
    ?.split(",")
    ?.mapNotNull { enc ->
        val kv = String(Base64.getDecoder().decode(enc), Charsets.UTF_8)
        val i = kv.indexOf('=')
        if (i > 0) kv.substring(0, i) to kv.substring(i + 1) else null
    }
    ?.toMap() ?: emptyMap()

fun brand(key: String, default: String): String =
    (project.findProperty(key) as String?) ?: dartDefines[key]?.takeIf { it.isNotBlank() } ?: default

val appId = brand("APP_ID", "com.example.openres")
val appName = brand("APP_NAME", "OpenRes")

// Release signing: key.properties (gitignored) or RELEASE_* environment variables.
// Without either, release builds fall back to the debug key so forks can build out of the box.
val keyPropsFile = rootProject.file("key.properties")
val keyProps = Properties()
if (keyPropsFile.exists()) {
    keyPropsFile.inputStream().use { keyProps.load(it) }
}
fun signing(key: String, env: String): String? = (keyProps[key] as String?) ?: System.getenv(env)
val releaseStoreFile = signing("storeFile", "RELEASE_STORE_FILE")

android {
    namespace = "com.example.openres"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = appId
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        manifestPlaceholders["appLabel"] = appName
        // Plain HTTP only when the configured server is http:// (local development).
        manifestPlaceholders["usesCleartextTraffic"] =
            brand("API_BASE_URL", "http://10.0.2.2:8000").startsWith("http://").toString()
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = signing("storePassword", "RELEASE_STORE_PASSWORD")
                keyAlias = signing("keyAlias", "RELEASE_KEY_ALIAS")
                keyPassword = signing("keyPassword", "RELEASE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseStoreFile != null) signingConfigs.getByName("release")
                            else signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // fused location, orientation (FOP) and Google's location-settings dialog (LocationBridge.kt)
    implementation("com.google.android.gms:play-services-location:21.3.0")
    implementation("androidx.activity:activity-ktx:1.9.3")   // enableEdgeToEdge
    implementation("com.google.android.play:integrity:1.4.0")
    implementation(platform("com.google.firebase:firebase-bom:35.1.0"))
    implementation("com.google.firebase:firebase-messaging")
}

flutter {
    source = "../.."
}
