import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.gradle.api.tasks.Exec
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.kapt")
    id("com.google.dagger.hilt.android")
}

val orbitRepositoryRoot = rootProject.projectDir.resolve("../../..").canonicalFile
val releaseKeystoreFile = providers.environmentVariable("ORBITTERM_RELEASE_KEYSTORE_FILE").orNull
val releaseKeystorePassword = providers.environmentVariable("ORBITTERM_RELEASE_KEYSTORE_PASSWORD").orNull
val releaseKeyAlias = providers.environmentVariable("ORBITTERM_RELEASE_KEY_ALIAS").orNull
val releaseKeyPassword = providers.environmentVariable("ORBITTERM_RELEASE_KEY_PASSWORD").orNull
val releaseSigningValues = listOf(
    releaseKeystoreFile,
    releaseKeystorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
)
val productionSigningConfigured = releaseSigningValues.all { !it.isNullOrBlank() }

if (releaseSigningValues.any { !it.isNullOrBlank() } && !productionSigningConfigured) {
    throw GradleException(
        "Production signing is partially configured. Provide all ORBITTERM_RELEASE_KEYSTORE_* values or none.",
    )
}

val orbitAndroidCoreBuild = tasks.register<Exec>("buildOrbitAndroidCore") {
    group = "build"
    description = "Builds checked Orbit Core Android libraries from Rust source."
    workingDir = orbitRepositoryRoot
    commandLine("bash", orbitRepositoryRoot.resolve("scripts/build_android_core.sh").absolutePath)
    inputs.dir(orbitRepositoryRoot.resolve("orbit-core/src"))
    inputs.file(orbitRepositoryRoot.resolve("orbit-core/Cargo.toml"))
    inputs.file(orbitRepositoryRoot.resolve("orbit-core/Cargo.lock"))
    inputs.file(orbitRepositoryRoot.resolve("scripts/build_android_core.sh"))
    outputs.files(
        project.layout.projectDirectory.file("src/main/jniLibs/arm64-v8a/liborbit_core.so"),
        project.layout.projectDirectory.file("src/main/jniLibs/x86_64/liborbit_core.so"),
    )
}

android {
    namespace = "com.orbitterm.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.orbitterm.android"
        minSdk = 26
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        versionCode = 1
        versionName = "1.0.0-multiplatform-alpha"
    }

    buildFeatures {
        compose = true
    }

    sourceSets {
        getByName("androidTest").assets.srcDir("$projectDir/schemas")
    }

    if (productionSigningConfigured) {
        signingConfigs.create("productionRelease") {
            storeFile = file(requireNotNull(releaseKeystoreFile))
            storePassword = requireNotNull(releaseKeystorePassword)
            keyAlias = requireNotNull(releaseKeyAlias)
            keyPassword = requireNotNull(releaseKeyPassword)
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            ndk {
                // Symbols are emitted as a separate build artifact for crash
                // symbolication; they are not packaged into the APK/AAB.
                debugSymbolLevel = "SYMBOL_TABLE"
            }
            if (productionSigningConfigured) {
                signingConfig = signingConfigs.getByName("productionRelease")
            }
        }

        // A minified, resource-shrunk and debug-signed build with an isolated
        // application ID. It can exercise login, lock and theme states on an
        // emulator without overwriting a user's production app or its data.
        create("smoke") {
            initWith(getByName("release"))
            applicationIdSuffix = ".smoke"
            versionNameSuffix = "-smoke"
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release", "debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    // Produce architecture-specific debug artifacts for direct simulator and
    // physical-device installation; no universal APK is emitted for this task.
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "x86_64")
            isUniversalApk = false
        }
    }
}

tasks.register("verifyReleaseSigning") {
    group = "verification"
    description = "Fails a signing-required build unless all production signing inputs are configured."
    doLast {
        val required = providers.environmentVariable("ORBITTERM_REQUIRE_PRODUCTION_SIGNING")
            .orNull
            ?.equals("true", ignoreCase = true) == true
        if (required && !productionSigningConfigured) {
            throw GradleException(
                "Production signing is required. Configure ORBITTERM_RELEASE_KEYSTORE_FILE, " +
                    "ORBITTERM_RELEASE_KEYSTORE_PASSWORD, ORBITTERM_RELEASE_KEY_ALIAS and " +
                    "ORBITTERM_RELEASE_KEY_PASSWORD in the protected CI environment.",
            )
        }
        logger.lifecycle(
            if (productionSigningConfigured) "Production signing inputs are configured."
            else "No production signing inputs configured; Release artifacts remain unsigned by design.",
        )
    }
}

tasks.matching { it.name.endsWith("JniLibFolders") || it.name.endsWith("NativeLibs") }
    .configureEach { dependsOn(orbitAndroidCoreBuild) }

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        freeCompilerArgs.add("-Xcontext-parameters")
    }
}

dependencies {
    implementation(project(":domain"))
    implementation(project(":core"))
    implementation(project(":design"))
    implementation(project(":data"))
    implementation(project(":feature"))
    implementation(platform("androidx.compose:compose-bom:2026.05.00"))
    implementation("androidx.activity:activity-compose:1.12.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("com.google.dagger:hilt-android:2.57.1")
    kapt("com.google.dagger:hilt-android-compiler:2.57.1")
    implementation("androidx.datastore:datastore-preferences:1.2.1")
    implementation("androidx.room:room-runtime:2.8.4")
    implementation("androidx.room:room-ktx:2.8.4")
    kapt("androidx.room:room-compiler:2.8.4")
    implementation("io.ktor:ktor-client-core:3.3.2")
    implementation("io.ktor:ktor-client-okhttp:3.3.2")
    implementation("io.ktor:ktor-client-content-negotiation:3.3.2")
    implementation("io.ktor:ktor-serialization-kotlinx-json:3.3.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("androidx.work:work-runtime-ktx:2.10.2")
    implementation("com.github.termux.termux-app:terminal-emulator:v0.118.3")
    implementation("com.github.termux.termux-app:terminal-view:v0.118.3")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.room:room-testing:2.8.4")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.05.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

dependencyLocking {
    // Release dependencies must be resolved from a reviewed, versioned graph.
    // Refreshing this file is an explicit review action (`--write-locks`).
    lockAllConfigurations()
}
