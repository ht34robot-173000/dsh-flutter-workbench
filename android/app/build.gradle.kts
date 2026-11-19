plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 顶层 import：`java` 在 Kotlin DSL 里是 ExtensionAware 的扩展名，
// 脚本体内写 java.util.Properties 会被解析成 gradle 的 java{} 块。
// 这个坑在 Kotlin 版工程里踩过（SimpleDateFormat / Properties 各一次），
// 直接照搬同一套做法。
import java.util.Properties

android {
    // 包名：**故意和 Kotlin 版的 com.dsh.workbench 不同**。
    //
    // 两个包名不同 → 手机上可以同时装着两个版本，各自独立配对、独立数据。
    // 迁移期这是必需的：Kotlin 版是每天在用的，不能让 Flutter 版把它顶掉。
    // 等 Flutter 版功能补齐、用一段时间没问题之后，再决定要不要收一个。
    namespace = "com.dsh.flutter_workbench"

    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_21.toString()
    }

    defaultConfig {
        applicationId = "com.dsh.flutter_workbench"
        // minSdk 26：和 Kotlin 版一致（Android 8.0+），
        // 这样两边支持范围相同，不会出现「Flutter 版装不上」的差异
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    /*
     * 正式签名。
     *
     * 直接复用 Kotlin 版那套 keystore（F:/dsh-mobile-signing/keystore.properties）。
     * 两个 App 包名不同，**共用一个 keystore 不会冲突** —— 签名是按包名校验的。
     * 好处是只需要维护一份密钥，不会出现「这个 App 的 keystore 丢哪去了」。
     */
    val keystorePropsFile = file("F:/dsh-mobile-signing/keystore.properties")
    val keystoreProps = Properties().apply {
        if (keystorePropsFile.exists()) {
            keystorePropsFile.inputStream().use { load(it) }
        }
    }
    fun prop(key: String): String? = keystoreProps.getProperty(key)?.takeIf { it.isNotBlank() }

    signingConfigs {
        if (keystorePropsFile.exists() && prop("storeFile") != null) {
            create("release") {
                storeFile = file(prop("storeFile")!!)
                storePassword = prop("storePassword")
                keyAlias = prop("keyAlias")
                keyPassword = prop("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 没有正式 keystore 就退回 debug 签名，保证任何机器都能编出可安装的包
            signingConfig = if (keystorePropsFile.exists() && prop("storeFile") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
        debug {
            signingConfig = if (keystorePropsFile.exists() && prop("storeFile") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
