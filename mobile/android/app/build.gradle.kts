plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

// ---- Shared brain: the Windows engine's Python package (engine/src) is the single source of truth.
// It's copied (code + src/data/app.json only) into the build on every configuration.
val snapyCoreDir = layout.buildDirectory.dir("snapy-core").get().asFile
delete(snapyCoreDir)
copy {
    from(file("../../../engine/src")) {
        exclude("**/__pycache__/**", "**/*.pyc")
    }
    into(File(snapyCoreDir, "src"))
}

android {
    namespace = "live.snapy.app"
    compileSdk = 35
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "live.snapy.app"
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // phones (arm64) + emulators (x86_64)
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
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

chaquopy {
    defaultConfig {
        version = "3.13"
        pip {
            install("requests")
        }
    }
    sourceSets {
        getByName("main") {
            srcDir(snapyCoreDir)
        }
    }
}

dependencies {
    // notifications (reminders)
    implementation("androidx.core:core-ktx:1.13.1")
    // "Hey Snapy": offline wake word (Apache-2.0), grammar-limited to the assistant's name
    implementation("com.alphacephei:vosk-android:0.3.75@aar")
    implementation("net.java.dev.jna:jna:5.18.1@aar")
}
