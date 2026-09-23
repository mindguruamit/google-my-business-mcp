# Vosk offline speech uses JNA; R8 must not strip or rename it.
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
-keep class org.vosk.** { *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**

# Floating prompter service is started by name from the plugin.
-keep class flutter.overlay.window.flutter_overlay_window.** { *; }
