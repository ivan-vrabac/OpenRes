# flutter_local_notifications reads its saved notifications with Gson, on boot and after an update:
# without these the shrinker strips the generic types and that receiver crashes the app.
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.dexterous.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type
