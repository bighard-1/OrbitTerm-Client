plugins {
    id("com.android.application") version "8.12.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.2.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.20" apply false
    id("org.jetbrains.kotlin.kapt") version "2.2.20" apply false
    id("com.google.dagger.hilt.android") version "2.57.1" apply false
}

// Keep build- and test-tool transitive dependencies on patched, binary-compatible
// lines. These configurations are locked and scanned alongside application
// dependencies because compromised developer/CI tooling is part of the release
// threat model even when the libraries are not packaged into the APK.
subprojects {
    configurations.configureEach {
        resolutionStrategy.force(
            "com.google.protobuf:protobuf-java:3.25.5",
            "com.google.protobuf:protobuf-kotlin:3.25.5",
            "io.netty:netty-buffer:4.1.136.Final",
            "io.netty:netty-codec:4.1.136.Final",
            "io.netty:netty-codec-http:4.1.136.Final",
            "io.netty:netty-codec-http2:4.1.136.Final",
            "io.netty:netty-codec-socks:4.1.136.Final",
            "io.netty:netty-common:4.1.136.Final",
            "io.netty:netty-handler:4.1.136.Final",
            "io.netty:netty-handler-proxy:4.1.136.Final",
            "io.netty:netty-resolver:4.1.136.Final",
            "io.netty:netty-transport:4.1.136.Final",
            "io.netty:netty-transport-native-unix-common:4.1.136.Final",
            "org.bouncycastle:bcpg-jdk18on:1.84",
            "org.bouncycastle:bcpkix-jdk18on:1.84",
            "org.bouncycastle:bcprov-jdk18on:1.84",
            "org.bouncycastle:bcutil-jdk18on:1.84",
        )
    }
}
