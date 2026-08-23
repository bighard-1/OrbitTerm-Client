# Keep only JNI methods resolved by their stable Java symbol names. Hilt,
# Compose, Room and kotlinx.serialization ship their own consumer rules.
-keepclasseswithmembernames class com.orbitterm.android.core.OrbitCoreBridge {
    native <methods>;
}

# Do not retain source or line information in the distributable APK. Native
# symbol tables are produced separately by the Android Gradle Plugin.
-renamesourcefileattribute SourceFile
-dontpreverify
