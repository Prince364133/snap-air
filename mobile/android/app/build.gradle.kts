plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Snapy's brain is the Dart core runtime (lib/core_runtime) reading the shared core/ from the
// Flutter assets (copied by `dart run tool/sync_core.dart`). No Python in the APK any more.

android {
    namespace = "live.snapy.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "live.snapy.app"
        // Android 8.0 (the plan's floor; also the ML Kit GenAI Prompt API minimum)
        minSdk = 26
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ABIs: Flutter's defaults (armeabi-v7a, arm64-v8a, x86_64). Ship per-ABI APKs / an AAB:
        //   flutter build apk --release --split-per-abi   (or flutter build appbundle)
    }

    buildTypes {
        release {
            // Signing with debug keys so release APK installs out-of-the-box on physical devices
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // notifications (reminders)
    implementation("androidx.core:core-ktx:1.13.1")
    // "Hey Snapy": offline wake word (Apache-2.0), grammar-limited to the assistant's name
    implementation("com.alphacephei:vosk-android:0.3.75@aar")
    implementation("net.java.dev.jna:jna:5.18.1@aar")
    // Gemini Nano on supported phones (ML Kit GenAI Prompt API; the model is managed by AICore,
    // not shipped in the APK). Latest on Google Maven as of 2026-11: 1.0.0-beta5.
    implementation("com.google.mlkit:genai-prompt:1.0.0-beta5")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // "Take a video / photo" (CaptureActivity, docs/ANDROID_NEXT_PLAN.md §7)
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-video:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
}
