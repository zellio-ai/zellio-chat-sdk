plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "ai.zellio.chat.sample"
    compileSdk = 36

    defaultConfig {
        applicationId = "ai.zellio.chat.sample"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
    }
    buildFeatures {
        compose = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// The offline demo serves the contract fixtures. They are copied at build time, never kept as a second copy.
abstract class CopyFixtures : DefaultTask() {
    @get:InputDirectory
    abstract val source: DirectoryProperty

    @get:OutputDirectory
    abstract val output: DirectoryProperty

    @TaskAction
    fun copy() {
        val target = output.get().asFile.resolve("fixtures")
        target.deleteRecursively()
        source.get().asFile.copyRecursively(target, overwrite = true)
    }
}

val copyFixtures = tasks.register<CopyFixtures>("copyContractFixtures") {
    source.set(rootProject.layout.projectDirectory.dir("../contract/v1/fixtures"))
    output.set(layout.buildDirectory.dir("generated/contract-assets"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copyFixtures, CopyFixtures::output)
    }
}

dependencies {
    implementation(project(":zellio-chat"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.activity.compose)
    implementation(libs.core.ktx)
}
