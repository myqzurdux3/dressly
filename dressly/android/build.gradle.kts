allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Some Flutter plugins (e.g. flutter_plugin_android_lifecycle, pulled in by
// file_picker / image_picker) now require compiling against Android SDK 36, but
// plugin modules otherwise inherit Flutter's default (34) and fail the AAR
// metadata check. Force every Android subproject to compileSdk 36. Reflection
// keeps this working regardless of the Android Gradle Plugin version's DSL, and
// the state guard handles projects that are already evaluated (via the
// evaluationDependsOn above) — for which afterEvaluate would throw.
subprojects {
    val forceCompileSdk = {
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {
            runCatching {
                androidExt.javaClass.getMethod("setCompileSdk", Integer::class.java)
                    .invoke(androidExt, 36)
            }.recoverCatching {
                androidExt.javaClass.getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(androidExt, 36)
            }
        }
    }
    if (state.executed) forceCompileSdk() else afterEvaluate { forceCompileSdk() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
