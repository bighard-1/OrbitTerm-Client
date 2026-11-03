# Keep only JNI methods resolved by their stable Java symbol names. Hilt,
# Compose, Room and kotlinx.serialization ship their own consumer rules.
-keepclasseswithmembernames class com.orbitterm.android.core.OrbitCoreBridge {
    native <methods>;
}

# Rust calls these instance methods by their literal JVM names/signatures.
# R8 cannot infer that reflection-like JNI edge from the receiver object.
-keep class com.orbitterm.android.core.NativeTerminalOutputRouter {
    public void onTerminalData(long, byte[]);
}
-keep class com.orbitterm.android.core.NativeSftpProgressRouter {
    public void onSftpTransferProgress(java.lang.String, long, long);
}
-keep class com.orbitterm.android.core.NativeConnectionEventRouter {
    public void onConnectionEvent(long, java.lang.String);
}

# Do not retain source or line information in the distributable APK. Native
# symbol tables are produced separately by the Android Gradle Plugin.
-renamesourcefileattribute SourceFile
-dontpreverify
