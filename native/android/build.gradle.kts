plugins {
    id("com.android.application") version "8.9.3"
    id("org.jetbrains.kotlin.android") version "2.1.20"
}

layout.buildDirectory.set(file("../.once/android-build"))

// Once supplies the pinned Native Shell 0.2.0 AAR and reviewed card bundle.
// SDK-free JVM builds keep the native text/action fallback.
val nshAndroidAar = providers.gradleProperty("nshAndroidAar")
val nshBundleDirectory = providers.gradleProperty("nshBundleDirectory")
val stageThreadCards by tasks.registering(Sync::class) {
    onlyIf { nshBundleDirectory.isPresent }
    from(nshBundleDirectory) { into("nsh") }
    from("../ATLAS_LICENSE")
    into(layout.buildDirectory.dir("threadCardAssets"))
    doFirst {
        for (name in listOf("bundle.js", "capabilities.json", "app.json")) {
            require(file(nshBundleDirectory.get()).resolve(name).isFile) { "Missing bundled card asset: $name" }
        }
    }
}

// JVM UI tests do not need JNI. An actual APK must be built with Once's library.
val stageNative by tasks.registering(Sync::class) {
    onlyIf { providers.gradleProperty("onceNativeLibrary").isPresent }
    from(providers.gradleProperty("onceNativeLibrary")) {
        into(providers.gradleProperty("onceNativeAbi").orElse("arm64-v8a"))
        rename { "libhabibi_core.so" }
    }
    into(layout.buildDirectory.dir("jniLibs"))
    doFirst {
        require(file(providers.gradleProperty("onceNativeLibrary").get()).isFile) { "Once-built JNI library does not exist" }
        require(providers.gradleProperty("onceNativeAbi").get() in listOf("arm64-v8a", "x86_64")) { "Unsupported ABI" }
    }
}

// Expose only reviewed public UI resources, not the adjacent inference scripts.
val stageHeartling by tasks.registering(Sync::class) {
    from("../resources/heartling") {
        include("heartling.png", "heartling.json")
        into("heartling")
    }
    from("../resources/themes.json")
    into(layout.buildDirectory.dir("heartlingAssets"))
    doFirst {
        for (name in listOf("heartling/heartling.png", "heartling/heartling.json", "themes.json")) {
            require(file("../resources/$name").isFile) { "Missing bundled UI asset: $name" }
        }
    }
}

android {
    namespace = "fyi.habibi.app"
    compileSdk = 35
    defaultConfig {
        applicationId = "fyi.habibi.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }
    buildFeatures.buildConfig = true
    sourceSets["main"].apply {
        manifest.srcFile("AndroidManifest.xml")
        java.setSrcDirs(listOf("src"))
        if (nshAndroidAar.isPresent) java.srcDir("nsh-src")
        res.setSrcDirs(listOf("res"))
        jniLibs.srcDir(layout.buildDirectory.dir("jniLibs"))
        assets.srcDir(layout.buildDirectory.dir("heartlingAssets"))
        if (nshBundleDirectory.isPresent) assets.srcDir(layout.buildDirectory.dir("threadCardAssets"))
    }
    sourceSets["debug"].apply {
        manifest.srcFile("debug/AndroidManifest.xml")
        res.setSrcDirs(listOf("debug/res"))
    }
    sourceSets["test"].java.setSrcDirs(listOf("test"))
    testOptions.unitTests.isIncludeAndroidResources = true
    testOptions.unitTests.all {
        it.systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
        it.testLogging { events("passed", "failed") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    if (nshAndroidAar.isPresent) {
        require(file(nshAndroidAar.get()).isFile) { "Native Shell 0.2.0 AAR does not exist" }
        implementation(files(nshAndroidAar.get()))
    }
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.core:core-ktx:1.15.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}

dependencyLocking { lockAllConfigurations() }
tasks.named("preBuild") { dependsOn(stageNative, stageThreadCards, stageHeartling) }
tasks.matching { it.name == "packageDebug" || it.name == "packageRelease" }.configureEach {
    doFirst {
        require(providers.gradleProperty("onceNativeLibrary").isPresent) { "Use Once or provide onceNativeLibrary and onceNativeAbi to package an APK" }
        require(nshAndroidAar.isPresent && nshBundleDirectory.isPresent) { "Use Once to package the pinned Native Shell SDK and reviewed card bundle" }
    }
}
tasks.register<Copy>("packageOnce") {
    dependsOn("assembleDebug")
    doFirst {
        require(providers.gradleProperty("onceNativeLibrary").isPresent) { "Once-built JNI library required" }
        require(providers.gradleProperty("onceNativeAbi").get() in listOf("arm64-v8a", "x86_64")) { "Unsupported ABI" }
    }
    from(layout.buildDirectory.file("outputs/apk/debug/HabibiAndroid-debug.apk"))
    into(providers.gradleProperty("onceOutputApk").map { file(it).parentFile })
    rename { providers.gradleProperty("onceOutputApk").map { file(it).name }.get() }
}
