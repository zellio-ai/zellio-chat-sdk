group = "ai.zellio.chat.flutter"
version = "1.0.1"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        if (project.findProperty("zellioChatUseMavenLocal") == "true") {
            mavenLocal()
        }
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "ai.zellio.chat.flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The native SDK. Change the version with -PzellioChatAndroidVersion=x.y.z (for example in gradle.properties).
    // To build against the checkout in sdks/android, see the "Build against the local Android SDK" part of the README.
    implementation("ai.zellio:zellio-chat:${project.findProperty("zellioChatAndroidVersion") ?: "1.0.1"}")
}
