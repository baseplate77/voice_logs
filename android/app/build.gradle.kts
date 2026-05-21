plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.nj.voxsynth"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.nj.voxsynth"
        // Spec targets Android 10+ (API 29). Required for FOREGROUND_SERVICE
        // service-type manifest entries and scoped storage for audio files.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // sherpa_onnx (Parakeet STT) and flutter_onnxruntime (e5 embeddings)
    // both ship libonnxruntime.so. The root Gradle file force-aligns
    // flutter_onnxruntime's com.microsoft.onnxruntime:onnxruntime-android
    // dependency to 1.24.3, matching sherpa_onnx_android_arm64 1.12.39.
    // Do not remove that alignment: onnxruntime4j_jni requires exact
    // versioned ORT symbols such as OrtGetApiBase@VERS_1.24.3.
    packaging {
        jniLibs {
            pickFirsts += setOf(
                "**/libonnxruntime.so",
                "**/libonnxruntime4j_jni.so",
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
